import Foundation
import AVFoundation
import AeroDJCore
import OSLog

/// Plays one DJ break between two songs.
///
/// Only prepared clips are played. A line with no clip, or a clip that will not
/// decode, skips the break and tells the UI; live speech is never used at a song
/// boundary, because its length is unknown and it would delay the next song.
///
/// The break runs `transition -> voice -> music`. Music is paused for the line and
/// resumed afterwards, whether the line finishes, is cancelled, fails, or times
/// out. Playback never stays paused because a callback was missed.
@MainActor
final class InterludePlaybackAdapter: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private let music: MusicKitService
    private var clipPlayer: AVAudioPlayer?
    private var queue: [AVAudioPlayer] = []
    private var finish: CheckedContinuation<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var outcome: BreakPlayerOutcome = .cancelled
    /// Retires the current clip on stop, so a late finish callback cannot end a later break.
    private var stopState = InterludeStopState()
    /// Indices and the stop reason only. No line text.
    private let log = Logger(subsystem: "com.aerodj.app", category: "playback")

    init(music: MusicKitService) {
        self.music = music
        super.init()
    }

    var isSpeaking: Bool { finish != nil }

    /// Real audio lifecycle for the DJ session. Emitted only from the player: started when
    /// AVAudioPlayer really starts, finished when the whole break ends, failed otherwise.
    /// `.revoked` is a consent stop, not a natural end and not a speech failure.
    enum Playback {
        case started(afterTrack: Int), finished(afterTrack: Int), failed(afterTrack: Int), revoked(afterTrack: Int)
    }
    var onPlayback: ((Playback) -> Void)?
    private var breakTrack = 0

    /// A line with no prepared clip. Routine, so the break is skipped quietly; the
    /// DJ status goes idle without an error. Only real failures are reported.
    func skipUnprepared() {
        music.skipInterlude()
    }

    /// Plays one prepared clip. A clip that won't decode skips the break.
    func play(clip: Data, line: String, afterTrack: Int) async {
        await play(clips: [clip], line: line, afterTrack: afterTrack)
    }

    /// Plays a prepared break: every clip back to back inside ONE break. Music is paused
    /// once before the first clip and resumed once after the last one.
    func play(clips: [Data], line: String, afterTrack: Int) async {
        breakTrack = afterTrack
        guard !isSpeaking, !line.isEmpty, !clips.isEmpty else {
            music.logBreakSkipped(after: afterTrack, reason: .notPlanned)
            music.skipInterlude()
            return
        }
        // A clip that won't decode skips the whole break; nothing is spoken partially.
        let players = clips.compactMap { try? AVAudioPlayer(data: $0) }
        guard players.count == clips.count, players.allSatisfy({ $0.duration > 0 }) else {
            music.logBreakSkipped(after: afterTrack, reason: .renderFailed)
            music.reportSpeechError("A DJ line could not be played and was skipped.")
            music.skipInterlude()
            return
        }
        queue = players
        let total = players.reduce(0) { $0 + $1.duration } + 2
        await runBreak(line: line, timeout: total) { self.startNextClip() }
        queue = []
        clipPlayer = nil
    }

    /// Starts the next queued clip. False if it could not start.
    private func startNextClip() -> Bool {
        guard !queue.isEmpty else { return false }
        let player = queue.removeFirst()
        player.delegate = self
        clipPlayer = player
        stopState.adopt(player: ObjectIdentifier(player))
        return player.play()
    }

    /// One clip finished. Continue with the next clip, or end the break.
    private func clipFinished(successful: Bool) {
        guard finish != nil else { return }
        guard successful else { finishBreak(.failed); return }
        if queue.isEmpty { finishBreak(.finished); return }
        if !startNextClip() { finishBreak(.failed) }
    }

    func stop() {
        guard stopState.stop(reason: nil) else { return }
        haltAudio()
    }

    /// Stops the clip that is already playing. Main-actor isolated. Idle is a no-op.
    ///
    /// Clears the player and its delegate before returning, so a late finish callback is ignored.
    /// The break ends as `.revoked`, not as a natural finish. Music is asked to resume once,
    /// and only when `NarrationResumePolicy` still permits it. A finished queue entry is not
    /// replayed: `resumeIfAllowed` refuses it, and `PlayerView` loads the next track.
    ///
    /// `DJBreakSession.purge` reaches this through `onBreakMustStop`. Sentinel calls purge;
    /// this method is the player entry point.
    func stopActiveBreak(reason: InterludeStopReason) {
        let effect = ActiveBreakStop.apply(
            isPlaying: stopState.isPlaying,
            reason: reason,
            mayAutoResume: music.mayAutoResume
        )
        guard effect.stopped, stopState.stop(reason: reason) else { return }
        log.notice("\(PlaybackLog.interludeStop(reason: reason), privacy: .public)")
        queue = []
        let player = clipPlayer
        clipPlayer = nil
        player?.delegate = nil
        player?.stop()
        outcome = .revoked
        finishBreak(.revoked)
    }

    /// Stops the speaking break before this returns. Safe from any isolation.
    ///
    /// On the main thread the player stops in this turn. Off the main thread the call
    /// waits until the main queue has stopped it. No task is left running. Idle is a
    /// no-op: nothing is paused, resumed, or reported. A finish callback from the
    /// stopped player is ignored, including one that arrives after a later break starts.
    ///
    /// Consent and deletion pass `.sourceRevoked`. The instance is the `PlayerView`
    /// interlude adapter.
    nonisolated func stopCurrentInterlude(reason: InterludeStopReason) {
        MainActorImmediate.run {
            guard self.stopState.stop(reason: reason) else { return }
            self.log.notice("\(PlaybackLog.interludeStop(reason: reason), privacy: .public)")
            self.haltAudio()
        }
    }

    private func haltAudio() {
        queue = []
        let player = clipPlayer
        clipPlayer = nil
        player?.delegate = nil
        player?.stop()
        finishBreak(.cancelled)
    }

    /// The one break lifecycle. `start` begins audio; completion comes from the
    /// delegate, or from the timeout if no callback arrives.
    private func runBreak(line: String, timeout seconds: Double, start: () -> Bool) async {
        music.pausePlayerForBreak()
        music.beginInterlude() // transition -> voice
        outcome = .cancelled

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finish = continuation
            stopState.begin()
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                self?.finishBreak(.cancelled)
            }
            // The line is reported as started only once audio is really playing.
            if start() {
                self.log.notice("\(PlaybackLog.breakStart(after: self.breakTrack), privacy: .public)")
                music.djStarted(line)
                onPlayback?(.started(afterTrack: breakTrack))
            } else {
                finishBreak(.failed)
            }
        }

        log.notice("\(PlaybackLog.breakEnd(after: breakTrack, result: outcome), privacy: .public)")

        let end = NarrationResumePolicy.narrationEnd(for: outcome)
        let decision = NarrationResumePolicy.decide(end, mayAutoResume: music.mayAutoResume, phase: music.audioState)
        music.completeNarration(decision)
        switch outcome {
        case .finished:
            onPlayback?(.finished(afterTrack: breakTrack))
        case .revoked:
            onPlayback?(.revoked(afterTrack: breakTrack))
        case .cancelled, .failed:
            onPlayback?(.failed(afterTrack: breakTrack))
        }
        if outcome == .revoked {
            // One resume, and only when the policy allows it. The finished entry stays stopped.
            if decision.resumeMusic, !music.currentEntryAlreadyFinished {
                await music.resumeIfAllowed()
            }
            return
        }
        // This break follows a natural end. The finished entry stays stopped; PlayerView
        // loads the next song after play returns.
        let action = NarrationResumePolicy.musicAfterBreak(
            entryAlreadyFinished: true,
            mayAutoResume: music.mayAutoResume,
            queueHasEntry: true
        )
        if action == .resumeCurrentEntry {
            await music.resumeIfAllowed()
        }
    }

    private func finishBreak(_ result: BreakPlayerOutcome) {
        stopState.end()
        timeout?.cancel()
        timeout = nil
        guard let continuation = finish else { return }
        finish = nil
        outcome = result
        continuation.resume()
    }

    // MARK: AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.stopState.acceptsDelegate(player: id) else { return }
            self.clipFinished(successful: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.stopState.acceptsDelegate(player: id) else { return }
            self.finishBreak(.failed)
        }
    }
}
