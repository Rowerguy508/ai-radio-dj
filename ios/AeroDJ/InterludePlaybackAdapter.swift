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
    /// A revoke that arrives before a clip player exists. See `PendingPlayStop`.
    private var pendingPlay = PendingPlayStop()
    /// Indices and the stop reason only. No line text.
    private let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    /// Live voice level for the on-air orb (-Fry). Read from AVAudioPlayer metering on the
    /// main actor at about 30 Hz while a clip plays: no tap, no audio-thread work, and no
    /// change to the audio session, route or ducking. See `DJSpeechLevelMeter`.
    private var levelMeter = DJSpeechLevelMeter()
    private var levelTicker: Task<Void, Never>?
    /// Where levels go. Set once in `AppDependencies.makeInterlude`. The store keeps the
    /// level at 0 unless the DJ state is `.speaking` for the same break.
    weak var speechLevel: DJPresentationStore?
    /// DJ talk-over (-Fry): every stop request, before it is applied, so the coordinator can
    /// drop or keep a break it took early. Reason nil is the untagged stop (pause, skip, new queue).
    var onStopRequested: (@MainActor (InterludeStopReason?, Int?) -> Void)?
    /// DJ talk-over: silence before the last queued clip (Echo's speech gap). 0 otherwise.
    private var closingGap: Double = 0
    /// DJ talk-over: the track whose duck is active (set by `duckForTalkover`, cleared by the unduck).
    private var duckedFor: Int?
    /// DJ talk-over: the voice fade plan per clip player (Core's `TalkoverVoiceRamp`).
    private var ramps: [ObjectIdentifier: TalkoverVoiceRamp] = [:]
    private var rampTask: Task<Void, Never>?

    // MARK: Interruption state (-Fry, see docs/dj-break-interruption.md)

    /// What a system interruption (Siri, a call, an alarm) does to the break on air. Core's
    /// pure state machine; this adapter only executes its actions.
    private var interruption = BreakInterruptionState()
    /// The break's script, one player per line, in order. `queue` is rebuilt from it on resume.
    private var scriptPlayers: [AVAudioPlayer] = []
    /// #332 P1: the cue id of each `scriptPlayers` line, for `.lineFinished`. Empty: not reported.
    private var lineCueIDs: [UUID] = []
    /// One per script line (`BreakResumeLine.lines(for:)`): what a resume re-checks (#379 N1).
    private var resumeLines: [BreakResumeLine] = []
    /// The acknowledgement player while it plays (never a script line).
    private var ackPlayer: AVAudioPlayer?
    /// The rendered acknowledgement (`BreakInterruptionAcknowledgement.line`), kept for the launch.
    private var ackData: Data?
    private var ackRender: Task<Void, Never>?
    /// Renders the acknowledgement. Set once in `AppDependencies` to the existing voice path with
    /// no attribution, so only on-device, free routes are used. Nil: resume without it.
    var acknowledgementClip: (@MainActor () async -> Data?)?
    /// `.began` notices seen by this adapter's own observer, and untagged `.interruption` stops
    /// from `MusicKitService` (the same notices, later, through its stream). See `systemInterruptionStop`.
    private var beganSeen = 0
    private var beganForwarded = 0
    /// The observer's view: a `.began` with no `.ended` after it yet.
    private var sessionInterrupted = false
    /// True while a system interruption holds the DJ voice of a break (paused, or held after an
    /// end without `shouldResume`). Observable and read-only, for the #373 stop detection
    /// (Echo): the app itself is holding its DJ voice; MusicKit is never paused, cleared or
    /// rewound by this.
    @Published private(set) var isHeldByInterruption = false
    /// PR B (-Nova): a rating that drops the open gap break's boundary stops its resume.
    private var ratingGate = StationRatingResumeGate()
    /// #388: one per script line of the open gap break (`StationRatingBreakLine.lines(for:)`): the
    /// song IDs it names and whether it is a briefing item. Never text. Empty: not known.
    private var ratingLines: [StationRatingBreakLine] = []

    init(music: MusicKitService) {
        self.music = music
        super.init()
        // Our own observer, so a break pauses before `MusicKitService`'s stream delivers the
        // same notice. Object nil, as in `AudioSessionMonitor`.
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    var isSpeaking: Bool { finish != nil }

    /// Real audio lifecycle for the DJ session. Emitted only from the player: started when
    /// AVAudioPlayer really starts, finished when the whole break ends, failed otherwise.
    /// `.revoked` is a consent stop, not a natural end and not a speech failure.
    /// `.lineFinished` (#332 P1, -Nova): one line of a boundary break played to its end (`cueID`
    /// from the `cueIDs` `play` got). Only that line counts as heard for the repeat limit.
    enum Playback {
        case started(afterTrack: Int), finished(afterTrack: Int), failed(afterTrack: Int), revoked(afterTrack: Int)
        case lineFinished(afterTrack: Int, cueID: UUID)
        /// #332 B1: sent once at `play`, before any line, when this break reports its lines.
        case reportsLines(afterTrack: Int)
    }
    var onPlayback: ((Playback) -> Void)?
    private var breakTrack = 0

    /// A line with no prepared clip. Routine, so the break is skipped quietly; the
    /// DJ status goes idle without an error. Only real failures are reported.
    func skipUnprepared() {
        music.skipInterlude()
    }

    /// Marks `afterTrack` as handed out, before `play` calls `begin`.
    /// A stop that arrives in that gap is kept for this break only when it is untagged
    /// or tagged with `afterTrack`. The natural-end boundary calls this once, synchronously,
    /// before it awaits break preparation. `play` must not call it again.
    func handOut(afterTrack: Int) {
        pendingPlay.handOut(afterTrack: afterTrack)
    }

    /// The boundary handed a break out and then found nothing to say.
    /// Drops that hand-out, including a stop that arrived during preparation.
    func abandonHandOut() {
        pendingPlay.abandonHandOut()
    }

    /// Plays one prepared clip. A clip that won't decode skips the break.
    func play(clip: Data, line: String, afterTrack: Int) async {
        await play(clips: [clip], line: line, afterTrack: afterTrack, resumeLines: [])
    }

    /// Plays a prepared break: every clip back to back inside ONE break. Music is paused
    /// once before the first clip and resumed once after the last one. `resumeLines`: one per
    /// clip (`BreakResumeLine.lines(for:)`), so a resume after an interruption can drop a time
    /// check that is no longer true (#379 N1). Any other count: no line is treated as timed.
    /// `ratingLines` (#388): one per clip (`StationRatingBreakLine.lines(for:)`), so a rating
    /// withdraws a paused break only when one of its lines names the song. Any other count: unknown.
    /// `cueIDs` (#332 P1): one per clip, its prepared cue id, so each line that plays to its end
    /// is reported (`.lineFinished`). Any other count: no line is reported.
    func play(clips: [Data], line: String, afterTrack: Int, resumeLines: [BreakResumeLine],
              ratingLines: [StationRatingBreakLine] = [], cueIDs: [UUID] = []) async {
        breakTrack = afterTrack
        guard !isSpeaking, !line.isEmpty, !clips.isEmpty else {
            // Handed out, but this break will not start. `.failed` clears `.ready`.
            abandonUnplayedBreak(.notPlayable, afterTrack: afterTrack, skip: .notPlanned)
            return
        }
        let known = ratingLines.count == clips.count ? ratingLines : []
        ratingGate.breakOpened(afterTrack: afterTrack, lines: known)
        self.ratingLines = known
        // The refusal is the stop held from the synchronous boundary hand-out.
        // An interruption that begins and ends during `naturalBoundary` clears the
        // live pause flag and still cancels here. Resume follows that held stop's policy.
        // A nil tag, or a tag for this afterTrack, cancels this break. A different tag
        // is ignored and not stored.
        let opened = pendingPlay.begin(afterTrack: afterTrack, mayAutoResume: music.mayAutoResume)
        guard opened.startAudio else {
            await cancelledPendingPlay(resumeMusic: opened.resumeMusic)
            return
        }
        // Extra guard only: the system is still holding playback and no stop was held.
        // Do not start a clip and do not resume onto the speaker.
        let admission = BreakPlayAdmissionPolicy.decide(
            pausedBySystem: music.pausedBySystem,
            mayAutoResume: music.mayAutoResume,
            phase: music.audioState,
            afterTrack: afterTrack
        )
        guard admission.startAudio else {
            _ = pendingPlay.stop(reason: .interruption, afterTrack: nil, mayAutoResume: false)
            _ = pendingPlay.admit(mayAutoResume: false)
            if let unplayed = admission.unplayed {
                applyUnplayed(unplayed, afterTrack: afterTrack, skip: admission.skipReason ?? .notPlanned)
            }
            return
        }
        // Decode while the play is pending. A revoke blocked on the main actor runs at the
        // yield, before any clip player is created.
        let players = clips.compactMap { try? AVAudioPlayer(data: $0) }
        await Task.yield()
        let admitted = pendingPlay.admit(mayAutoResume: music.mayAutoResume)
        guard admitted.startAudio else {
            await cancelledPendingPlay(resumeMusic: admitted.resumeMusic)
            return
        }
        // A clip that won't decode skips the whole break; nothing is spoken partially.
        guard players.count == clips.count, players.allSatisfy({ $0.duration > 0 }) else {
            abandonUnplayedBreak(.decodeFailed, afterTrack: afterTrack, skip: .renderFailed)
            music.reportSpeechError("A DJ line could not be played and was skipped.")
            return
        }
        queue = players
        scriptPlayers = players
        lineCueIDs = cueIDs.count == players.count ? cueIDs : []
        // #332 B1: the session counts only reported lines, even if the break ends `.finished` early.
        if !lineCueIDs.isEmpty { onPlayback?(.reportsLines(afterTrack: afterTrack)) }
        self.resumeLines = resumeLines.count == players.count
            ? resumeLines : players.map { BreakResumeLine(seconds: $0.duration) }
        let total = players.reduce(0) { $0 + $1.duration } + 2
        await runBreak(line: line, timeout: total) { self.startNextClip() }
        queue = []
        clipPlayer = nil
        scriptPlayers = []
        lineCueIDs = []
        self.resumeLines = []
        self.ratingLines = []
    }

    /// The break was handed out and audio will not start. Reports `.failed` for `afterTrack`
    /// and returns the boundary transition to music. Does not resume the player.
    private func abandonUnplayedBreak(_ reason: HandedOutBreakSkip, afterTrack: Int, skip: DJBreakSkipReason) {
        pendingPlay.abandonHandOut()
        let report = HandedOutBreakReport.skipped(reason, afterTrack: afterTrack, mayAutoResume: music.mayAutoResume)
        applyUnplayed(report, afterTrack: afterTrack, skip: skip)
    }

    /// Applies an unplayed report. Moves the state machine back toward music when the
    /// report names that transition. Never calls `resumeIfAllowed`.
    private func applyUnplayed(_ report: HandedOutBreakEffect, afterTrack: Int, skip: DJBreakSkipReason) {
        if case .playbackFailed(let k) = report.event {
            onPlayback?(.failed(afterTrack: k))
        }
        music.logBreakSkipped(after: afterTrack, reason: skip)
        switch report.resume.audioEvent {
        case .noInterlude?:
            music.skipInterlude()
        case .interludeEnded?:
            music.endInterlude()
        default:
            break
        }
    }

    /// Starts the next queued clip. False if it could not start.
    private func startNextClip() -> Bool {
        guard !queue.isEmpty else { return false }
        let player = queue.removeFirst()
        player.delegate = self
        player.isMeteringEnabled = true
        clipPlayer = player
        stopState.adopt(player: ObjectIdentifier(player))
        if let line = scriptPlayers.firstIndex(where: { $0 === player }) { interruption.lineStarted(line) }
        let ramp = ramps[ObjectIdentifier(player)]
        if let ramp { player.volume = ramp.startVolume }
        if queue.isEmpty, closingGap > 0 {
            // Talk-over closing line: starts `closingGap` after MAIN ends, on the player clock.
            let gap = closingGap
            closingGap = 0
            let started = player.play(atTime: player.deviceCurrentTime + gap)
            if started, let ramp { runRamp(ramp, for: player, after: gap) }
            return started
        }
        let started = player.play()
        if started, let ramp { runRamp(ramp, for: player, after: 0) }
        return started
    }

    /// DJ talk-over voice fades (-Fry): up to `gain` over `fadeIn` once the clip's audio starts
    /// (`delay` for a scheduled clip), down to 0 over `fadeOut` before its end. Only while this
    /// player is still the current clip of a live break.
    private func runRamp(_ ramp: TalkoverVoiceRamp, for player: AVAudioPlayer, after delay: Double) {
        rampTask?.cancel()
        let id = ObjectIdentifier(player)
        rampTask = Task { @MainActor [weak self] in
            if delay > 0 { do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return } }
            guard let self, let p = self.clipPlayer, ObjectIdentifier(p) == id, self.finish != nil else { return }
            p.setVolume(ramp.gain, fadeDuration: ramp.fadeIn)
            let hold = ramp.fadeOutAt
            if hold > 0 { do { try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) } catch { return } }
            guard ramp.fadeOut > 0, let q = self.clipPlayer, ObjectIdentifier(q) == id, self.finish != nil else { return }
            q.setVolume(0, fadeDuration: ramp.fadeOut)
        }
    }

    // MARK: Speech level (-Fry)

    /// Starts the ~30 Hz level reads once audio is really playing. Each tick reads the
    /// current clip's meter and publishes one value on the main actor.
    private func startLevelMeter() {
        stopLevelMeter()
        let track = breakTrack
        let nanos = UInt64(DJSpeechLevelMeter.interval * 1_000_000_000)
        levelTicker = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                guard let self, !Task.isCancelled, self.finish != nil else { return }
                let now = ContinuousClock.now
                let elapsed = now - last
                last = now
                let dt = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                self.publishLevel(dt: dt, afterTrack: track)
            }
        }
    }

    private func publishLevel(dt: Double, afterTrack: Int) {
        // Between clips, or a player that is not playing, reads as silence.
        var dBFS = -Float.infinity
        if let player = clipPlayer, player.isPlaying {
            player.updateMeters()
            for channel in 0..<max(1, player.numberOfChannels) {
                dBFS = max(dBFS, player.averagePower(forChannel: channel))
            }
        }
        let level = levelMeter.sample(dBFS: dBFS, dt: dt)
        speechLevel?.updateSpeechLevel(level, afterTrack: afterTrack)
    }

    /// Stops the reads and drops the published level to 0 now, before the state event
    /// for the end of the break arrives.
    private func stopLevelMeter() {
        levelTicker?.cancel()
        levelTicker = nil
        levelMeter.reset()
        speechLevel?.updateSpeechLevel(0, afterTrack: breakTrack)
    }

    /// One clip finished. Continue with the next clip, or end the break.
    private func clipFinished(successful: Bool) {
        guard finish != nil else { return }
        // Paused or held by an interruption: no next line starts (a finish callback that was
        // already in flight when the pause came in; the interrupted line replays on resume).
        guard !interruption.isHolding else { return }
        if let ack = ackPlayer, clipPlayer === ack {
            // The acknowledgement ended (or failed): the script resumes at the interrupted line.
            ackPlayer = nil
            applyInterruption(interruption.acknowledgementEnded())
            return
        }
        guard successful else { finishBreak(.failed); return }
        // #332 P1: this script line played to its end (not the acknowledgement, handled above).
        if let player = clipPlayer, let index = scriptPlayers.firstIndex(where: { $0 === player }),
           lineCueIDs.indices.contains(index) {
            onPlayback?(.lineFinished(afterTrack: breakTrack, cueID: lineCueIDs[index]))
        }
        if queue.isEmpty { finishBreak(.finished); return }
        if !startNextClip() { finishBreak(.failed) }
    }

    /// Untagged stop. `skip()` and pause send this. It cancels a handed-out or pending
    /// break, and a break that is already playing.
    func stop() {
        onStopRequested?(nil, nil)
        _ = pendingPlay.stop(reason: .sourceRevoked, afterTrack: nil, mayAutoResume: music.mayAutoResume)
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
    /// Revoke stop used by `stopCurrentInterlude(reason: .sourceRevoked)`.
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
    /// Consent and deletion pass `.sourceRevoked`. The instance is the app-scoped
    /// interlude adapter.
    ///
    /// A stop that arrives while a play is handed out or pending, before the clip player
    /// exists, is kept by `PendingPlayStop`. That includes a revoke, an interruption, and
    /// a route removal, so the break cannot start on the speaker at the boundary. `begin`
    /// or `admit` then starts no audio and resumes music once when that is still allowed.
    /// A nil tag, and a tag for the handed-out `afterTrack`, cancel that break. A tag for
    /// a different `afterTrack` is ignored and not stored. A stop while idle, with nothing
    /// handed out, does not cancel the next break. A stop that never reaches this method,
    /// because the session hook was nil, is outside this guarantee.
    nonisolated func stopCurrentInterlude(reason: InterludeStopReason, afterTrack: Int? = nil) {
        MainActorImmediate.run {
            self.onStopRequested?(reason, afterTrack)
            // A tag scopes a playing stop to that afterTrack. Nil fails closed. An
            // interruption or a route removal also cancels a handed-out or pending break.
            // Revoke of a playing clip ends as `.revoked`. Other playing stops keep the
            // existing halt, which ends the break as cancelled.
            switch InterludeBoundaryStop.action(
                reason: reason,
                afterTrack: afterTrack,
                isPlaying: self.stopState.isPlaying,
                playingTrack: self.breakTrack
            ) {
            case .ignore:
                return
            case .cancelPending(let tag):
                _ = self.pendingPlay.stop(reason: reason, afterTrack: tag, mayAutoResume: self.music.mayAutoResume)
            case .stopPlaying:
                // A system interruption pauses the break instead (`BreakInterruptionState`).
                if reason == .interruption, afterTrack == nil, self.systemInterruptionStop() { return }
                if reason == .sourceRevoked {
                    self.stopActiveBreak(reason: reason)
                } else {
                    guard self.stopState.stop(reason: reason) else { return }
                    self.log.notice("\(PlaybackLog.interludeStop(reason: reason), privacy: .public)")
                    self.haltAudio()
                }
            }
        }
    }

    /// The play was revoked before a clip player existed. Music was not paused for it.
    /// Resume once when the entry is still current and auto-resume is allowed. PlayerView
    /// loads the next track when this returns.
    private func cancelledPendingPlay(resumeMusic: Bool) async {
        log.notice("\(PlaybackLog.interludeStop(reason: .sourceRevoked), privacy: .public)")
        log.notice("\(PlaybackLog.breakEnd(after: self.breakTrack, result: .revoked), privacy: .public)")
        onPlayback?(.revoked(afterTrack: breakTrack))
        // F3 (-Fry): leave `.transition` before anything resumes. A call that is still
        // ringing here must find no active break when it ends, or music stays paused.
        let cancel = HeldBoundaryStopReport.cancellation(
            afterTrack: breakTrack, mayAutoResume: resumeMusic, phase: music.audioState)
        switch cancel.audioEvent {
        case .noInterlude?:
            music.skipInterlude()
        case .interludeEnded?:
            music.endInterlude()
        default:
            break
        }
        if resumeMusic, !music.currentEntryAlreadyFinished {
            await music.resumeIfAllowed()
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
                // Echo (#125): stop the clip first, so it can't mix over the next song and the
                // session release in completeNarration doesn't throw "busy". -Atlas
                self?.endBreakSilencingClip(.timeout, result: .cancelled)
            }
            interruption.breakStarted(.boundary)
            prefetchAcknowledgement()
            // The line is reported as started only once audio is really playing.
            if start() {
                TalkoverAudioSession.noteImplicitActivation() // AVAudioPlayer.play activates the session
                self.log.notice("\(PlaybackLog.breakStart(after: self.breakTrack), privacy: .public)")
                music.djStarted(line)
                onPlayback?(.started(afterTrack: breakTrack))
                startLevelMeter()
            } else {
                finishBreak(.failed)
            }
        }

        log.notice("\(PlaybackLog.breakEnd(after: self.breakTrack, result: self.outcome), privacy: .public)")

        let end = NarrationResumePolicy.narrationEnd(for: outcome)
        let decision = NarrationResumePolicy.decide(end, mayAutoResume: music.mayAutoResume, phase: music.audioState)
        music.completeNarration(decision)
        TalkoverAudioSession.noteReleased() // completeNarration deactivated the session
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

    /// Timeout and decode-error ends. Follows `BreakEndSequence`: the clip is silenced and its
    /// delegate cleared before `finishBreak`, which lets `completeNarration` release the session.
    private func endBreakSilencingClip(_ trigger: BreakEndTrigger, result: BreakPlayerOutcome) {
        for step in BreakEndSequence.appSteps(for: trigger) {
            switch step {
            case .stopClip:
                queue = []
                let player = clipPlayer
                clipPlayer = nil
                player?.delegate = nil
                player?.stop()
            case .finishBreak:
                finishBreak(result)
            case .releaseSession:
                break // completeNarration, after the continuation resumes.
            }
        }
    }

    private func finishBreak(_ result: BreakPlayerOutcome) {
        interruption.breakEnded()
        ratingGate.breakClosed()
        isHeldByInterruption = false
        ackPlayer = nil
        stopLevelMeter()
        rampTask?.cancel()
        rampTask = nil
        stopState.end()
        timeout?.cancel()
        timeout = nil
        guard let continuation = finish else { return }
        finish = nil
        outcome = result
        continuation.resume()
    }

    // MARK: DJ talk-over (-Fry, flagged; see docs/dj-talkover.md)

    /// Decodes clips for the talk-over planner. Nil for a clip that will not decode or is empty.
    /// Nothing is prepared here: `prepareToPlay()` activates the session (Apple doc), mix-only,
    /// before the duck, which then is not a fresh activation. `play()` prepares on its own.
    func decodeTalkover(_ clips: [Data]) -> [AVAudioPlayer?] {
        clips.map { data in
            guard let player = try? AVAudioPlayer(data: data), player.duration > 0 else { return nil }
            return player
        }
    }

    /// The talk-over duck, `duckLead` before the voice (Core's `TalkoverSessionTiming`). Same
    /// guards as the voice: not while a break speaks, the system holds playback, or the user paused.
    func duckForTalkover(afterTrack: Int) -> Bool {
        guard !isSpeaking, !music.pausedBySystem, music.mayAutoResume else { return false }
        guard TalkoverAudioSession.duck(afterTrack: afterTrack) else { return false }
        duckedFor = afterTrack
        return true
    }

    /// Releases a duck whose voice never spoke (paused, song over, replaced, seek or stop).
    func releaseTalkoverDuck() {
        guard let k = duckedFor, !isSpeaking else { return }
        duckedFor = nil
        TalkoverAudioSession.release(afterTrack: k, spoken: false)
    }

    /// Plays a talk-over voice while music keeps playing: MAIN over the outro (the session
    /// ducks other audio, which on device includes `ApplicationMusicPlayer`; unverified), then
    /// the closing line after `closingGap`. Music is never paused for it and never resumed by
    /// it. The duck was activated `duckLead` earlier by `duckForTalkover`; the talk-over ends it
    /// itself (`TalkoverAudioSession.release`) before `completeNarration`, and the song swells
    /// (system ramp). Our voice fades in and out (`TalkoverVoiceRamp`). `onStarted` gets the
    /// uptime of the real start.
    ///
    /// Same stop paths as a normal break: `stop()`, `stopCurrentInterlude`, the timeout, and
    /// the delegate. `.speaking` is reported only when AVAudioPlayer really starts.
    func playTalkover(players: [AVAudioPlayer], gains: [Float], closingGap gap: Double, line: String,
                      afterTrack: Int, onStarted: @escaping @MainActor (Double) -> Void) async -> BreakPlayerOutcome {
        guard !isSpeaking else { return .failed }
        guard duckedFor == afterTrack else { releaseTalkoverDuck(); return .failed }
        guard !players.isEmpty, !line.isEmpty else { releaseTalkoverDuck(); return .failed }
        // Same guard as a boundary break: the system is holding playback, or the user paused.
        guard !music.pausedBySystem, music.mayAutoResume else { releaseTalkoverDuck(); return .cancelled }
        breakTrack = afterTrack
        ramps = [:]
        for (player, gain) in zip(players, gains + Array(repeating: 1, count: max(0, players.count - gains.count))) {
            ramps[ObjectIdentifier(player)] = TalkoverVoiceRamp.plan(duration: player.duration, gain: gain)
        }
        queue = players
        scriptPlayers = players
        lineCueIDs = []    // #332: no per-line reports; the session counts a talk-over on `.finished`
        resumeLines = []   // a talk-over stops at an interruption and is never resumed
        closingGap = players.count > 1 ? max(0, gap) : 0
        let total = players.reduce(0) { $0 + $1.duration } + closingGap + 2
        outcome = .cancelled
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finish = continuation
            stopState.begin()
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000)) } catch { return }
                self?.endBreakSilencingClip(.timeout, result: .cancelled)
            }
            interruption.breakStarted(.talkover)
            if startNextClip() {
                log.notice("\(PlaybackLog.breakStart(after: self.breakTrack), privacy: .public)")
                music.djStarted(line)
                onPlayback?(.started(afterTrack: breakTrack))
                let startedAt = ProcessInfo.processInfo.systemUptime
                TalkoverAudioSession.voiceStarted(afterTrack: afterTrack, at: startedAt)
                onStarted(startedAt)
                startLevelMeter()
            } else {
                finishBreak(.failed)
            }
        }
        log.notice("\(PlaybackLog.breakEnd(after: self.breakTrack, result: self.outcome), privacy: .public)")
        let end = NarrationResumePolicy.narrationEnd(for: outcome)
        let decision = NarrationResumePolicy.decide(end, mayAutoResume: music.mayAutoResume, phase: music.audioState)
        // The unduck: the talk-over's own release sequence (deactivate with notify, then the
        // normal category). completeNarration then finds the session already inactive. Music
        // was never paused, so nothing is resumed.
        duckedFor = nil
        TalkoverAudioSession.release(afterTrack: afterTrack, spoken: true)
        music.completeNarration(decision)
        switch outcome {
        case .finished: onPlayback?(.finished(afterTrack: breakTrack))
        case .revoked: onPlayback?(.revoked(afterTrack: breakTrack))
        case .cancelled, .failed: onPlayback?(.failed(afterTrack: breakTrack))
        }
        queue = []
        clipPlayer = nil
        scriptPlayers = []
        closingGap = 0
        ramps = [:]
        return outcome
    }

    /// #388: the talk-over line on air now (its index in the clips `playTalkover` got), or nil
    /// when no talk-over voice is on air (none started, it ended, or it was stopped, including by
    /// an interruption). The closing line counts from when it is scheduled (during its gap).
    var talkoverSpeakingLine: Int? {
        guard finish != nil, duckedFor != nil, let player = clipPlayer else { return nil }
        return scriptPlayers.firstIndex { $0 === player }
    }

    /// #388: drops talk-over lines that have not started yet (indices into the clips
    /// `playTalkover` got); the line on air plays on. Dropping the closing line drops its gap.
    func dropQueuedTalkoverLines(_ lines: [Int]) {
        guard finish != nil, duckedFor != nil else { return }
        let gone = Set(lines.compactMap { scriptPlayers.indices.contains($0) ? ObjectIdentifier(scriptPlayers[$0]) : nil })
        guard !gone.isEmpty else { return }
        if let last = queue.last, gone.contains(ObjectIdentifier(last)) { closingGap = 0 }
        queue.removeAll { gone.contains(ObjectIdentifier($0)) }
    }

    /// A seek while the talk-over speaks: fade the voice out over `seconds`, then stop it.
    /// The break ends as cancelled and is not replayed.
    func fadeOutTalkover(seconds: Double = 0.25) {
        guard let player = clipPlayer, finish != nil else { return }
        queue = []
        closingGap = 0
        rampTask?.cancel()
        rampTask = nil
        player.setVolume(0, fadeDuration: seconds)
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, let current = self.clipPlayer, ObjectIdentifier(current) == id,
                  self.stopState.stop(reason: nil) else { return }
            self.haltAudio()
        }
    }

    // MARK: System interruptions (-Fry, see docs/dj-break-interruption.md)

    /// `AVAudioSession.interruptionNotification`, parsed on the posting thread and applied on
    /// the main actor before this returns (`MainActorImmediate`).
    @objc nonisolated private func sessionInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
        switch type {
        case .began: MainActorImmediate.run { self.interruptionBegan() }
        case .ended: MainActorImmediate.run { self.interruptionEnded(shouldResume: shouldResume) }
        @unknown default: return
        }
    }

    /// `.began`. A break on air pauses (gap break) or stops (talk-over). No break on air: nothing
    /// here; `MusicKitService` still holds music and cancels a handed-out break as before.
    private func interruptionBegan() {
        beganSeen += 1
        sessionInterrupted = true
        guard finish != nil else { return }
        let action = interruption.interruptionBegan(at: ProcessInfo.processInfo.systemUptime)
        if action == .stopTalkover {
            onStopRequested?(.interruption, nil)
            guard stopState.stop(reason: .interruption) else { return }
            log.notice("\(PlaybackLog.interludeStop(reason: .interruption), privacy: .public)")
            haltAudio()
            return
        }
        applyInterruption(action)
    }

    /// `.ended`. Only a paused break acts: acknowledgement then the interrupted line
    /// (`shouldResume`), or the break closes silently and music stays held (no `shouldResume`).
    /// No acknowledgement for a short interruption, and at most one per break (#379 N3). When
    /// no line left is still true (a stale time check, #379 N1), the break ends without one.
    private func interruptionEnded(shouldResume: Bool) {
        sessionInterrupted = false
        guard finish != nil, case .paused(let line) = interruption.phase else { return }
        // The listener already pressed Play during the interruption: never talk over music.
        let resume = shouldResume && !music.isPlaying
        // PR B: a rating dropped this break's boundary while it was paused. Never re-air it.
        if resume, !ratingGate.mayResume { endWithdrawnBreak(line: line); return }
        if resume {
            let left = BreakResumePlan.plan(from: line, lines: resumeLines, now: Date())
            if left.lines.isEmpty {
                endStaleBreak(left.drop ?? BreakResumeDrop.remaining(resumeLines, from: line, reason: .allStale))
                return
            }
        }
        let ack = resume ? acknowledgementPlayer() : nil
        let action = interruption.interruptionEnded(shouldResume: resume, acknowledgementReady: ack != nil,
                                                    at: ProcessInfo.processInfo.systemUptime)
        if case .playAcknowledgement = action { ackPlayer = ack }
        if case .stayPaused(let line) = action {
            traceDrop(BreakResumeDrop.remaining(resumeLines, from: line, reason: shouldResume ? .musicPlaying : .noResume))
        }
        applyInterruption(action)
    }

    /// Every line left is past its window: nothing true to say, so the break ends now (no
    /// apology) and music follows as after any finished break.
    private func endStaleBreak(_ drop: BreakResumeDrop) {
        log.notice("dj break dropped on resume: no line still true line=\(drop.line, privacy: .public)")
        traceDrop(drop)
        queue = []
        let player = clipPlayer
        clipPlayer = nil
        player?.delegate = nil
        player?.stop()
        finishBreak(.finished)
    }

    /// PR B (-Nova): a rating dropped the paused break's boundary. Ends as a finished break, no
    /// apology and no line, so music follows as after any break. Nothing about the rating is logged;
    /// the lines it did not air are, by kind (counts only, #387 N1, like `traceDrop`).
    private func endWithdrawnBreak(line: Int) {
        let lines = resumeLines.count == scriptPlayers.count
            ? resumeLines : scriptPlayers.map { BreakResumeLine(seconds: $0.duration) }
        let withdrawn = StationRatingWithdrawnLines.remaining(lines, from: line, ratingLines: ratingLines)
        log.notice("dj break withdrawn before resume line=\(line, privacy: .public) dropped=\(withdrawn.count, privacy: .public) timeChecks=\(withdrawn.timeChecks, privacy: .public) briefing=\(withdrawn.briefing, privacy: .public)")
        #if AERODJ_P0_DIAG
        if withdrawn.count > 0 {
            let k = breakTrack
            P0EventTraceHost.shared.talkover { trace, t in _ = trace.breakInterruptionWithdrawn(withdrawn, afterTrack: k, at: t) }
        }
        #endif
        queue = []
        let player = clipPlayer
        clipPlayer = nil
        player?.delegate = nil
        player?.stop()
        finishBreak(.finished)
    }

    /// A rating dropped the break at boundary `k` (PR B, via `TalkoverCoordinator.ratingChanged`).
    /// When that is the open gap break and one of its lines names a song in `excluding` (#388,
    /// Echo's N2; lines unknown: any), a later interruption resume ends it instead of replaying.
    func boundaryDropped(afterTrack k: Int, excluding songIDs: Set<String>) {
        ratingGate.boundaryDropped(afterTrack: k, excluding: songIDs)
    }

    /// #379 N2: lines a paused break dropped, by kind (P0 diag builds only; counts and codes).
    private func traceDrop(_ drop: BreakResumeDrop) {
        guard drop.count > 0 else { return }
        log.notice("dj break interruption drop reason=\(drop.reason.rawValue, privacy: .public) dropped=\(drop.count, privacy: .public) timeChecks=\(drop.timeChecks, privacy: .public)")
        #if AERODJ_P0_DIAG
        let k = breakTrack
        P0EventTraceHost.shared.talkover { trace, t in _ = trace.breakInterruptionDrop(drop, afterTrack: k, at: t) }
        #endif
    }

    /// `MusicKitService`'s untagged `.interruption` stop for a playing break: the same `.began`
    /// this adapter's observer gets, through its stream, usually later. True: taken here (no
    /// halt). One the observer already counted is a duplicate, including a late one after a
    /// quick began/ended (it must not pause a resumed break): ignored, the observer owns it.
    /// Otherwise (the observer's copy has not run yet) the break pauses now and the observer's
    /// copy is a no-op. A talk-over falls through to the existing halt. DJBreakSession's queue
    /// change stop is tagged (`afterTrack`) and never comes here.
    private func systemInterruptionStop() -> Bool {
        beganForwarded += 1
        // Already counted: still ongoing (a break that started inside the interruption pauses
        // now; a paused one is unchanged), or already ended (a stale copy: ignored).
        if beganForwarded <= beganSeen, !sessionInterrupted { return true }
        let action = interruption.interruptionBegan(at: ProcessInfo.processInfo.systemUptime)
        switch action {
        case .stopTalkover: return false
        case .none: return interruption.isHolding
        default:
            applyInterruption(action)
            return true
        }
    }

    private func applyInterruption(_ action: BreakInterruptionState.Action) {
        switch action {
        case .none:
            break
        case .pause(let line):
            pauseForInterruption(line: line)
        case .stopTalkover:
            if stopState.stop(reason: .interruption) { haltAudio() }
        case .playAcknowledgement(let line):
            playAcknowledgement(thenLine: line)
        case .resume(let line):
            resumeScript(fromLine: line)
        case .stayPaused(let line):
            // Nothing restarts on its own. The rest of the break is dropped (ends as cancelled)
            // so no break stays open: music stays held (the session policy has no
            // `mayAutoResume`), and the listener's Play resumes music as for any held break.
            log.notice("dj break held after interruption line=\(line, privacy: .public)")
            if stopState.stop(reason: .interruption) { haltAudio() }
        }
        isHeldByInterruption = interruption.isHolding
    }

    /// Freezes the break: the voice pauses, and no timeout, ramp, meter or next line runs.
    private func pauseForInterruption(line: Int) {
        log.notice("dj break paused by interruption line=\(line, privacy: .public)")
        timeout?.cancel()
        timeout = nil
        rampTask?.cancel()
        rampTask = nil
        stopLevelMeter()
        queue = []
        closingGap = 0
        clipPlayer?.pause()
        prefetchAcknowledgement()
        // Apple does not promise an `.ended`: a break never stays paused (and open) for good.
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(BreakInterruptionState.maxPausedSeconds * 1_000_000_000)) } catch { return }
            guard let self, self.finish != nil else { return }
            let action = self.interruption.pauseExpired()
            if case .stayPaused(let line) = action {
                self.traceDrop(BreakResumeDrop.remaining(self.resumeLines, from: line, reason: .pauseExpired))
            }
            self.applyInterruption(action)
        }
    }

    /// The acknowledgement, then line `thenLine` onward. Does not start: the script resumes.
    private func playAcknowledgement(thenLine line: Int) {
        guard let ack = ackPlayer else { applyInterruption(interruption.acknowledgementEnded()); return }
        queue = [ack]
        armTimeout(ack.duration + remainingSeconds(fromLine: line) + 2)
        if startNextClip() {
            TalkoverAudioSession.noteImplicitActivation()
            startLevelMeter()
        } else {
            ackPlayer = nil
            applyInterruption(interruption.acknowledgementEnded())
        }
    }

    /// Line `line` (from its beginning) to the end of the script, with a new timeout. Each line
    /// is re-checked against the clock now (`BreakResumePlan`, #379 N1): a time check that would
    /// no longer be true when it airs is dropped rather than spoken.
    private func resumeScript(fromLine line: Int) {
        guard line >= 0, line < scriptPlayers.count else { finishBreak(.finished); return }
        // PR B: dropped during the apology. The script does not come back.
        guard ratingGate.mayResume else { endWithdrawnBreak(line: line); return }
        let lines = resumeLines.count == scriptPlayers.count
            ? resumeLines : scriptPlayers.map { BreakResumeLine(seconds: $0.duration) }
        let plan = BreakResumePlan.plan(from: line, lines: lines, now: Date())
        if let drop = plan.drop, plan.lines.isEmpty { endStaleBreak(drop); return }
        if let drop = plan.drop { traceDrop(drop) }
        let rest = plan.lines.map { scriptPlayers[$0] }
        for player in rest { player.stop(); player.currentTime = 0 }
        log.notice("dj break resumed after interruption line=\(line, privacy: .public)")
        queue = rest
        armTimeout(rest.reduce(0) { $0 + $1.duration } + 2)
        if startNextClip() {
            TalkoverAudioSession.noteImplicitActivation()
            startLevelMeter()
        } else {
            finishBreak(.failed)
        }
    }

    private func remainingSeconds(fromLine line: Int) -> Double {
        guard line >= 0, line < scriptPlayers.count else { return 0 }
        return scriptPlayers[line...].reduce(0) { $0 + $1.duration }
    }

    /// Same end as the break's own timeout: silence the clip, end as cancelled.
    private func armTimeout(_ seconds: Double) {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            self?.endBreakSilencingClip(.timeout, result: .cancelled)
        }
    }

    /// A fresh player for the rendered acknowledgement. Nil when none is rendered yet, it will
    /// not decode, or it is longer than `BreakInterruptionAcknowledgement.maxSeconds`.
    private func acknowledgementPlayer() -> AVAudioPlayer? {
        guard let data = ackData, let player = try? AVAudioPlayer(data: data), player.duration > 0,
              player.duration <= Double(BreakInterruptionAcknowledgement.maxSeconds) else { return nil }
        return player
    }

    /// Renders the acknowledgement once per launch (on-device, $0; the renderer caches it too).
    private func prefetchAcknowledgement() {
        guard ackData == nil, ackRender == nil, let render = acknowledgementClip else { return }
        ackRender = Task { @MainActor [weak self] in
            let data = await render()
            guard let self else { return }
            self.ackData = data
            self.ackRender = nil
        }
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
            // The acknowledgement is optional: a decode error there resumes the script.
            if let ack = self.ackPlayer, ObjectIdentifier(ack) == id { self.clipFinished(successful: false); return }
            self.endBreakSilencingClip(.decodeError, result: .failed)
        }
    }
}
