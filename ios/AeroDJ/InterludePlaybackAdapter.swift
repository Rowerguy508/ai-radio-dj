import Foundation
import AVFoundation
import AeroDJCore

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
    private var finish: CheckedContinuation<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var outcome: Outcome = .cancelled

    /// How a break ended. Only `.finished` means the whole line was heard.
    private enum Outcome { case finished, cancelled }

    init(music: MusicKitService) {
        self.music = music
        super.init()
    }

    var isSpeaking: Bool { finish != nil }

    /// A line with no prepared clip. Routine, so the break is skipped quietly; the
    /// DJ status goes idle without an error. Only real failures are reported.
    func skipUnprepared() {
        music.skipInterlude()
    }

    /// Plays a pre-rendered clip. A clip that won't decode skips the break.
    func play(clip: Data, line: String) async {
        guard !isSpeaking, !line.isEmpty else {
            music.skipInterlude()
            return
        }
        guard let player = try? AVAudioPlayer(data: clip), player.duration > 0 else {
            music.reportSpeechError("A DJ line could not be played and was skipped.")
            music.skipInterlude()
            return
        }
        player.delegate = self
        clipPlayer = player
        await runBreak(line: line, timeout: player.duration + 2) {
            player.play()
        }
        clipPlayer = nil
    }

    func stop() {
        clipPlayer?.stop()
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
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                self?.finishBreak(.cancelled)
            }
            // The line is reported as started only once audio is really playing.
            if start() {
                music.djStarted(line)
            } else {
                finishBreak(.cancelled)
            }
        }

        music.endInterlude() // voice -> music
        if outcome == .finished { music.djFinished() } else { music.djCancelled() }
        // Music returns only if the user still wants it and the system is not holding it.
        await music.resumeIfAllowed()
    }

    private func finishBreak(_ result: Outcome) {
        timeout?.cancel()
        timeout = nil
        guard let continuation = finish else { return }
        finish = nil
        outcome = result
        continuation.resume()
    }

    // MARK: AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishBreak(flag ? .finished : .cancelled) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finishBreak(.cancelled) }
    }
}
