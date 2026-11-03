import AVFoundation
import AeroDJCore
import Foundation
import MusicKit
import OSLog

// DJ talk-over (owner request on #195, -Fry). Flagged: `DJTalkoverFlag`, a Settings toggle in
// every build (unset ON on a live station, OFF on the fixture test station). See docs/dj-talkover.md.
//
// NOT device-validated. Nothing here has run on an iPhone; the owner's TestFlight run is the
// first time. The checklist is in the doc and the PR.

/// The app session while the talk-over voice plays. `.duckOthers` lowers other audio while
/// our session is active, and ends when it is deactivated with `.notifyOthersOnDeactivation`.
/// Depth and ramp are the system's.
/// https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers
///
/// Session order (-Fry): Apple says ducking begins when the session is ACTIVATED. The steps are
/// Core's `TalkoverSessionSequence` (quiet off, duck option, on), so the activation is a real
/// one even if something activated the session before. Nothing in the talk-over path calls
/// `prepareToPlay()` before this: that call activates the session too (Apple doc).
enum TalkoverAudioSession {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "playback")

    /// The app's own record of whether it activated the session (no public getter exists).
    /// Set by the duck and by a gap-break clip start; cleared by every release.
    @MainActor private(set) static var appActivated = false
    /// Uptime of the last successful duck activation, for the duck-to-voice delay.
    @MainActor private(set) static var duckedAt: Double?

    @MainActor static func noteImplicitActivation() { appActivated = true }
    @MainActor static func noteReleased() { appActivated = false; duckedAt = nil }

    /// Runs `TalkoverSessionSequence.duck`. False: the activation failed; the session is
    /// released again and the break falls back to the gap.
    @MainActor static func duck(afterTrack k: Int) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let otherBefore = session.isOtherAudioPlaying
        let hintBefore = session.secondaryAudioShouldBeSilencedHint
        let activeBefore = appActivated
        let musicBefore = musicIsPlaying()
        var preOffCode = 0
        var options: AVAudioSession.CategoryOptions?
        var activated = false
        defer {
            probe(TalkoverDuckProbe(otherBefore: otherBefore, hintBefore: hintBefore, activated: activated,
                                    otherAfter: session.isOtherAudioPlaying,
                                    hintAfter: session.secondaryAudioShouldBeSilencedHint,
                                    activeBefore: activeBefore, preDeactivateCode: preOffCode,
                                    optionsRaw: options.map { Int($0.rawValue) },
                                    duckOthersSet: options.map { $0.contains(.duckOthers) },
                                    outputVolumePercent: Int((session.outputVolume * 100).rounded()),
                                    musicBefore: musicBefore, musicAfter: musicIsPlaying()), afterTrack: k)
        }
        do {
            for step in TalkoverSessionSequence.duck {
                switch step {
                case .deactivate(let notify):
                    // Not fatal: an inactive session may report an error here; the activation decides.
                    let off: AVAudioSession.SetActiveOptions = notify ? [.notifyOthersOnDeactivation] : []
                    do { try session.setActive(false, options: off) }
                    catch { preOffCode = (error as NSError).code }
                case .setDuckCategory:
                    try session.setCategory(.playback, mode: .default, options: [.duckOthers])
                    options = session.categoryOptions // read back before the activation
                case .activate:
                    try session.setActive(true)
                case .restoreCategory:
                    restore()
                }
            }
            activated = true
            appActivated = true
            duckedAt = ProcessInfo.processInfo.systemUptime
            settleProbe(afterTrack: k)
            return true
        } catch {
            log.error("talkover duck failed code=\((error as NSError).code, privacy: .public)")
            _ = release(afterTrack: k, spoken: false)
            return false
        }
    }

    /// Runs `TalkoverSessionSequence.release`: the unduck after the voice (`spoken`), or the
    /// release of a duck whose voice never spoke. Returns the deactivation's error code (0: ok).
    @MainActor @discardableResult
    static func release(afterTrack k: Int, spoken: Bool) -> Int {
        let session = AVAudioSession.sharedInstance()
        var code = 0
        for step in TalkoverSessionSequence.release {
            switch step {
            case .deactivate(let notify):
                let off: AVAudioSession.SetActiveOptions = notify ? [.notifyOthersOnDeactivation] : []
                do { try session.setActive(false, options: off) }
                catch {
                    let failed = (error as NSError).code
                    code = failed
                    log.error("talkover unduck failed code=\(failed, privacy: .public)")
                }
            case .restoreCategory:
                restore()
            case .setDuckCategory, .activate:
                break // never part of a release
            }
        }
        noteReleased()
        #if AERODJ_P0_DIAG
        let sample = sessionSample()
        P0EventTraceHost.shared.talkover { trace, t in
            _ = trace.talkoverUnduck(errorCode: code, released: !spoken, sample, afterTrack: k, at: t)
        }
        #endif
        return code
    }

    /// The voice really started: DIAG row with the duck-to-voice delay.
    @MainActor static func voiceStarted(afterTrack k: Int, at uptime: Double) {
        #if AERODJ_P0_DIAG
        let ms = TalkoverSessionTiming.duckToVoiceMs(duckedAt: duckedAt, voiceAt: uptime)
        let music = musicIsPlaying()
        P0EventTraceHost.shared.talkover { trace, t in
            _ = trace.talkoverDuckToVoice(ms: ms, musicPlaying: music, afterTrack: k, at: t)
        }
        #endif
    }

    /// DIAG duck probe (codes only). Release builds log nothing.
    @MainActor private static func probe(_ p: TalkoverDuckProbe, afterTrack k: Int) {
        #if AERODJ_P0_DIAG
        P0EventTraceHost.shared.talkover { trace, t in _ = trace.talkoverDuckProbe(p, afterTrack: k, at: t) }
        #endif
    }

    /// DIAG: the session 0.5 s after the duck, once the system ramp should be down.
    @MainActor private static func settleProbe(afterTrack k: Int) {
        #if AERODJ_P0_DIAG
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let sample = sessionSample()
            P0EventTraceHost.shared.talkover { trace, t in _ = trace.talkoverDuckSettled(sample, afterTrack: k, at: t) }
        }
        #endif
    }

    #if AERODJ_P0_DIAG
    @MainActor private static func sessionSample() -> P0EventTrace.TalkoverSessionSample {
        let session = AVAudioSession.sharedInstance()
        return P0EventTrace.TalkoverSessionSample(otherAudio: session.isOtherAudioPlaying,
                                                  secondaryHint: session.secondaryAudioShouldBeSilencedHint,
                                                  outputVolumePercent: Int((session.outputVolume * 100).rounded()),
                                                  musicPlaying: musicIsPlaying())
    }
    #endif

    /// Echo's #374 follow-up (-Fry): whether Apple Music is playing right now, read from
    /// `ApplicationMusicPlayer.playbackStatus`. Read-only; DIAG probe rows only. A Duo run shows
    /// whether the duck (or the lead before the voice) ever pauses Apple Music.
    @MainActor static func musicIsPlaying() -> Bool {
        ApplicationMusicPlayer.shared.state.playbackStatus == .playing
    }

    /// Back to the app's normal category (on an inactive session: activates nothing).
    static func restore() {
        let options: AVAudioSession.CategoryOptions = AppAudioSessionConfig.mixesWithOthers ? [.mixWithOthers] : []
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)
        } catch {
            log.error("talkover restore failed code=\((error as NSError).code, privacy: .public)")
        }
    }
}

/// Clip loudness for mixed voices (cloud MAIN, on-device closing line). Reads up to 20 s of
/// PCM from a temporary copy of the clip, deleted at once. Nil if it cannot be read.
enum TalkoverClipLoudness {
    static func rmsDBFS(_ data: Data) -> Float? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talkover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            let file = try AVAudioFile(forReading: url)
            let frames = AVAudioFrameCount(min(file.length, Int64(file.processingFormat.sampleRate * 20)))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
            try file.read(into: buffer, frameCount: frames)
            guard let channels = buffer.floatChannelData else { return nil }
            var samples: [Float] = []
            samples.reserveCapacity(Int(buffer.frameLength) * Int(buffer.format.channelCount))
            for c in 0..<Int(buffer.format.channelCount) {
                samples.append(contentsOf: UnsafeBufferPointer(start: channels[c], count: Int(buffer.frameLength)))
            }
            let value = TalkoverLoudness.rmsDBFS(samples)
            return value.isFinite ? value : nil
        } catch {
            return nil
        }
    }
}

/// Runs the talk-over for one boundary at a time. App-scoped (made in `AppDependencies`), so a
/// fold, rotation or a view going away does not touch it.
///
/// Flow (flag on): in the last seconds of song k, when the break is already rendered, take it
/// through `DJBreakSession.naturalBoundary` (every consent and stale-next check still runs),
/// decode it, plan it (`TalkoverPlanner`), and start the voice at `voiceStartAt`. At the
/// natural end, the binder in PlayerView hands the boundary here (`claimsBoundary`), which
/// waits for the plan's play cue before the binder calls `startNextTrack`. A break that plans
/// as a hard break, or whose voice could not start, is played at the natural end exactly as
/// today (`interlude.play`).
@MainActor
final class TalkoverCoordinator {
    private let music: MusicKitService
    private let interlude: InterludePlaybackAdapter
    private let djSession: DJBreakSession
    private let defaults: UserDefaults
    private let unsetDefault: Bool
    private var config = TalkoverConfig()
    private let log = Logger(subsystem: "com.aerodj.app", category: "playback")

    /// The song on air, from `onSongStarted`. Nil between songs.
    private var song: (index: Int, duration: Double?)?
    /// Owned boundaries and the run in flight (pure, tested in AeroDJCore). Keys are queue
    /// index plus track ID, so a new queue's index 0 never collides with the old queue's.
    private var book = TalkoverBook()
    /// A break taken early that has not been spoken: played in the gap at the natural end.
    private var held: (afterTrack: Int, prepared: PreparedDJBreak)?
    /// The run in flight; `book` retires it on every terminal path.
    private var run: TalkoverRun? {
        get { book.run }
        set { book.run = newValue }
    }
    private var taking: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var generation = 0
    /// The boundary whose gap fallback was handed out to the interlude (once per boundary).
    private var handedOut: Int?
    /// #388 (-Nova): what each line of the talk-over on air names, for a never while it speaks.
    private var ratingCut = StationRatingTalkoverCut()

    init(music: MusicKitService, interlude: InterludePlaybackAdapter, djSession: DJBreakSession,
         defaults: UserDefaults = .standard,
         unsetDefault: Bool = DJTalkoverFlag.unsetDefault(isTestStation: false)) {
        self.music = music
        self.interlude = interlude
        self.djSession = djSession
        self.defaults = defaults
        self.unsetDefault = unsetDefault
        interlude.onStopRequested = { [weak self] reason, afterTrack in self?.stopRequested(reason, afterTrack: afterTrack) }
    }

    var isEnabled: Bool { DJTalkoverFlag.isEnabled(defaults: defaults, unsetDefault: unsetDefault) }

    /// Starts the position watch. 1 Hz until the arm window, 10 Hz inside it; nothing when off.
    func start() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = self?.tick() ?? 1.0
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    // MARK: Hooks (one line each in PlayerView's binder and AppDependencies)

    /// `onSongStarted`. A new song: any held break for another boundary is stale.
    func songStarted(index: Int, duration: Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        let started = key(index)
        // Across a replacement or refill there is no sample: L stays as it was (Atlas #210).
        if !book.isReplacement(started), var r = run, r.afterTrack == index - 1, r.nextCalledAt != nil {
            if let measured = r.nextAudible(at: now) {
                let next = config.updatedLatency(current: config.startLatency, measured: measured)
                trace(.latency(measured: measured, next: next, r.afterTrack))
                log.notice("\(TalkoverLog.latency(afterTrack: r.afterTrack, measuredMs: Int(measured * 1000), nextMs: Int(next * 1000)), privacy: .public)")
                config.startLatency = next
            }
            run = r
            reportMisses()
        }
        let replaced = book.songStarted(started)
        if let h = held, replaced || h.afterTrack != index - 1 { drop(h.afterTrack) }
        song = (index, duration)
    }

    /// `onSongSkipped`: song `index` was cut; its break never plays.
    func songSkipped(index: Int) {
        if song?.index == index { song = nil }
        cancelRun(.skip)
        if held?.afterTrack == index { drop(index) }
        book.songSkipped(key(index))
    }

    /// The listener's ratings changed (PR B, #388; `StationQueuePlayer.ratingChanged`). `excluded`:
    /// queued songs the station now leaves out; `boundaries`: the breaks that could name them
    /// (`StationRatingBreakDrop`). Decided by each line's song IDs (`SpokenAttribution.trackMetadata`),
    /// never by text, and never logged with a song or a rating. Song `k` itself keeps playing.
    /// - A talk-over speaking a line that names one: that line fades (`TalkoverVoiceRamp.fadeSeconds`)
    ///   and the rest of its break is dropped, once (Orion's spec). One that does not: it plays on,
    ///   and only its queued lines that name the song are dropped. The run is cancelled only with its
    ///   voice stopping (Fry #387 nit 1: a cancelled run with a live voice let the next song start
    ///   under it).
    /// - A break taken early and not spoken (held, maybe armed): narrowed to the lines that do not
    ///   name the song (Echo's #387 N2); an armed run is cancelled so the narrowed break plays in the
    ///   gap. Nothing left: dropped.
    /// - A gap break paused by an interruption (#379): withdrawn only if one of its lines names it.
    /// A take still waiting on the session is narrowed by the session itself (`songsExcluded`).
    func ratingChanged(excluded: Set<String>, boundaries: [Int]) {
        switch ratingCut.ratingChanged(excluded: excluded, speakingLine: interlude.talkoverSpeakingLine) {
        case let .fadeAndDropBreak(k, dropped):
            trace(.ratedNever(dropped, k))
            // Sentinel's #396 N2: these two lines are Debug only (nothing in Release os_log); P0 diag
            // builds keep the trace row above. Codes and counts only.
            #if DEBUG
            log.notice("dj talkover faded, break dropped after=\(k, privacy: .public) line=\(dropped.line, privacy: .public) dropped=\(dropped.count, privacy: .public)")
            #endif
            interlude.fadeOutTalkover(seconds: TalkoverVoiceRamp.fadeSeconds)
            if run?.afterTrack == k { cancelRun(.skip) }   // its voice is fading out right now
            if held?.afterTrack == k { drop(k) }
        case let .dropQueued(k, lines):
            #if DEBUG
            log.notice("dj talkover lines dropped after=\(k, privacy: .public) dropped=\(lines.count, privacy: .public)")
            #endif
            interlude.dropQueuedTalkoverLines(lines)
        case .none:
            break
        }
        if let h = held, !(run?.afterTrack == h.afterTrack && run?.isSpeaking == true) {
            let k = h.afterTrack
            let rest = StationRatingBreakNarrowing.narrowed(h.prepared, excluding: excluded)
            if rest != h.prepared {
                if let counts = StationRatingBreakNarrowing.droppedCounts(h.prepared, excluding: excluded) {
                    trace(.narrowed(counts, k))
                }
                // The armed voice was decoded from the old lines: it must not speak them.
                if run?.afterTrack == k { cancelRun(.skip) }
                if let rest { held = (k, rest) } else { drop(k) }
            }
        }
        for k in boundaries { interlude.boundaryDropped(afterTrack: k, excluding: excluded) }
    }

    /// `onSongSeeked` (AppDependencies.wireSongSeek).
    func songSeeked(index: Int) {
        guard var r = run, r.afterTrack == index else { return }
        let action = r.userSeeked(to: music.playbackTime, config: config)
        run = r
        apply(action, afterTrack: index)
    }

    /// The natural end of song k, synchronously from the binder. True: this coordinator owns
    /// the boundary; the binder must not hand out or take a break, and awaits `boundary(k)`.
    func claimsBoundary(_ k: Int) -> Bool {
        guard book.owns(key(k)) else { return false }
        // The song is over: a take still waiting for the voice start stops waiting.
        song = nil
        // A break not yet spoken may play in the gap through the normal path; hand it out now,
        // before any await, so a stop in the next await is kept (PendingPlayStop).
        if !(run?.isSpeaking ?? false) {
            interlude.handOut(afterTrack: k)
            handedOut = k
        }
        return true
    }

    /// The owned boundary. Returns when the next song should be started.
    func boundary(_ k: Int) async {
        await taking?.value
        let now = ProcessInfo.processInfo.systemUptime
        song = nil
        if var r = run, r.afterTrack == k, r.voiceStartedAt != nil || r.phase == .armed {
            let end = r.naturalEnd(at: now)
            run = r
            if !end.abandoned, r.isSpeaking {
                if handedOut == k { interlude.abandonHandOut(); handedOut = nil }
                music.beginInterlude() // transition -> voice while the voice is still audible
                held = nil
                await waitUntil(now + end.waitSeconds, afterTrack: k)
                if r.plan.mode == .outroOnly {
                    // The next song follows the voice, as today: wait for the real end (max 3 s).
                    let limit = ProcessInfo.processInfo.systemUptime + 3
                    while interlude.isSpeaking, ProcessInfo.processInfo.systemUptime < limit {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                } else if run?.cancelled == nil {
                    run?.nextPlayCalled(at: ProcessInfo.processInfo.systemUptime)
                }
                book.release(key(k))
                return
            }
            if !end.abandoned {
                // The voice already ended or was cancelled: nothing to wait for, no replay.
                if handedOut == k { interlude.abandonHandOut(); handedOut = nil }
                reportMisses()
                music.skipInterlude()
                book.release(key(k))
                return
            }
            reportMisses()
        }
        // Never spoke (song beat the voice, seek back, voice could not start, hard-break plan):
        // the held break plays in the gap, as today.
        run = nil // never spoke: the run is over, the gap break takes the boundary
        book.release(key(k))
        if handedOut != k { interlude.handOut(afterTrack: k) }
        handedOut = nil
        guard let h = held, h.afterTrack == k else {
            interlude.abandonHandOut()
            music.logBreakSkipped(after: k, reason: PlaybackLog.noBreakReason(djSession.lastNoBreak))
            music.skipInterlude()
            return
        }
        held = nil
        // Today's hard break: everything in the gap, music paused (it already ended).
        let line = h.prepared.cues.map(\.text).joined(separator: " ")
        let clips = h.prepared.clips.map(\.audio.data)
        guard !line.isEmpty, !clips.isEmpty else {
            interlude.abandonHandOut()
            djSession.playbackFailed(afterTrack: k)
            music.skipInterlude()
            return
        }
        await interlude.play(clips: clips, line: line, afterTrack: k,
                            resumeLines: BreakResumeLine.lines(for: h.prepared),
                            ratingLines: StationRatingBreakLine.lines(for: h.prepared))
    }

    // MARK: Private

    /// One watch step. Returns the next interval.
    private func tick() -> Double {
        guard isEnabled, let song, let duration = song.duration, music.isPlaying else { return 1.0 }
        let k = song.index
        let position = music.playbackTime
        guard let armAt = TalkoverPlanner.armAt(duration: duration, config: config) else { return 1.0 }
        if position < armAt - 1 { return 1.0 }
        guard book.mayArm(key(k)), taking == nil, held == nil, !interlude.isSpeaking else { return 0.1 }
        guard position >= armAt else { return 0.1 }
        generation += 1
        let token = generation
        run = nil // a finished run for an earlier boundary
        book.claim(key(k))
        taking = Task { @MainActor [weak self] in
            await self?.take(k, token: token)
            self?.taking = nil
        }
        return 0.1
    }

    private func take(_ k: Int, token: Int) async {
        guard await djSession.breakIsReady(afterTrack: k) else {
            // Not rendered yet: leave it to the boundary, exactly as today.
            book.release(key(k))
            trace(.decision(.hardBreak(.tooLateToArm), k))
            return
        }
        guard token == generation, song?.index == k else { book.release(key(k)); return }
        guard let taken = await djSession.naturalBoundary(afterTrack: k) else {
            return // owned: the boundary skips (consent or stale-next dropped everything)
        }
        guard token == generation, song?.index == k else { djSession.talkoverDropped(afterTrack: k); return }
        // #388: the session filtered at its last await; a rating since then narrows here too.
        if let counts = StationRatingBreakNarrowing.droppedCounts(taken, excluding: djSession.excludedSongIDs) {
            trace(.narrowed(counts, k))   // Echo's #396 room N1: counts only
        }
        guard let prepared = StationRatingBreakNarrowing.narrowed(taken, excluding: djSession.excludedSongIDs) else {
            djSession.talkoverDropped(afterTrack: k)
            return // owned: the boundary skips, as when the session drops everything
        }
        held = (k, prepared)
        let players = interlude.decodeTalkover(prepared.clips.map(\.audio.data))
        guard let resolved = TalkoverClips.resolve(decoded: players.map { $0?.duration }, voice: prepared.talkoverVoice) else {
            decide(.hardBreak(.voiceInvalid), afterTrack: k)
            return // a MAIN clip failed: the boundary path skips it, as today
        }
        let next = music.queue.indices.contains(k + 1) ? music.queue[k + 1].duration : nil
        let decision = TalkoverPlanner.decide(flag: isEnabled,
                                              track: TalkoverTrack(duration: song?.duration, position: music.playbackTime),
                                              voice: resolved.voice, nextTrackDuration: next, config: config)
        decide(decision, afterTrack: k)
        guard let plan = decision.plan else { return }
        run = TalkoverRun(afterTrack: k, plan: plan)
        let chosen = Array(players.prefix(resolved.count).compactMap { $0 })
        let gains = Self.gains(for: prepared, clips: Array(prepared.clips.prefix(resolved.count)))
        // Duck `duckLead` before the voice (Core's `TalkoverSessionTiming`), so the system ramp is
        // down before the first word, then wait for the planned voice start on the song clock.
        await waitOnSongClock(until: TalkoverSessionTiming.duckAt(voiceStartAt: plan.voiceStartAt, config: config), afterTrack: k)
        guard stillArmed(k) else {
            if song?.index == k, !music.isPlaying { cancelRun(.userStop) }
            return
        }
        guard interlude.duckForTalkover(afterTrack: k) else {
            // The duck did not activate (or the system holds playback): the gap break takes it.
            if var r = run, r.cancelled == nil, r.phase != .done {
                _ = r.stopped(.voiceFailed)
                run = r
                trace(.cancel(.voiceFailed, k))
                book.retireIfDone()
            }
            return
        }
        await waitOnSongClock(until: plan.voiceStartAt, afterTrack: k)
        guard stillArmed(k) else {
            // Ducked but never spoke (paused, song over, replaced, seek or stop): release the duck.
            interlude.releaseTalkoverDuck()
            if song?.index == k, !music.isPlaying { cancelRun(.userStop) }
            return
        }
        let line = prepared.cues.filter { !(resolved.droppedClosing && $0.id == prepared.talkOverCueID) }
            .map(\.text).joined(separator: " ")
        // #388: one per clip handed to the voice, in order (`chosen` is a prefix of the clips).
        let ratingLines = Array(StationRatingBreakLine.lines(for: prepared).prefix(chosen.count))
        let resumeLines = Array(BreakResumeLine.lines(for: prepared).prefix(chosen.count))
        let voiceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Fry #387 nit 2: a drop or stop between `stillArmed` and this task (one hop) cancelled
            // the run; the voice must not start for it. The duck was taken: release it.
            guard self.run?.afterTrack == k, self.run?.cancelled == nil, self.run?.phase == .armed else {
                self.interlude.releaseTalkoverDuck()
                self.book.retireIfDone()
                return
            }
            let position = self.music.playbackTime
            let outcome = await self.interlude.playTalkover(
                players: chosen, gains: gains, closingGap: resolved.closingGap, line: line, afterTrack: k,
                onStarted: { [weak self] at in
                    guard let self else { return }
                    self.run?.voiceStarted(at: at, songPosition: position, config: self.config)
                    self.held = nil // spoken now: never replayed in the gap
                    self.ratingCut.speechStarted(afterTrack: k, lines: chosen.count == ratingLines.count ? ratingLines : [],
                                                 resumeLines: resumeLines)
                })
            if self.ratingCut.afterTrack == k { self.ratingCut.speechEnded() }
            if outcome == .finished { self.run?.voiceFinished(at: ProcessInfo.processInfo.systemUptime) }
            // Not finished and not cancelled: it never started, or it failed mid-line. Either way
            // the run ends here, so it can retire (it never stays `.speaking`).
            if let r = self.run, r.cancelled == nil, r.phase != .done {
                _ = self.run?.stopped(.voiceFailed)
                self.trace(.cancel(.voiceFailed, k))
            }
            if self.run?.naturalEndAt != nil || self.run?.cancelled != nil { self.reportMisses() }
            self.book.retireIfDone()
        }
        _ = voiceTask
    }

    /// One gain per clip. A single voice keeps unity (today's level); mixed voices are matched.
    private static func gains(for prepared: PreparedDJBreak, clips: [RenderedClip]) -> [Float] {
        // MAIN may be cloud and the closing line on-device (per-cue `mayLeaveDevice` gate).
        let voices = Set(clips.map { "\($0.audio.providerID)/\($0.audio.voiceID)" })
        guard voices.count > 1 else { return clips.map { _ in 1 } }
        return TalkoverLoudness.gains(rmsDBFS: clips.map { TalkoverClipLoudness.rmsDBFS($0.audio.data) })
    }

    private func key(_ k: Int) -> TalkoverBook.Key {
        TalkoverBook.Key(index: k, trackID: music.queue.indices.contains(k) ? music.queue[k].id : "")
    }

    /// Waits on the song clock while the run for `k` is still armed and song k plays.
    private func waitOnSongClock(until target: Double, afterTrack k: Int) async {
        while run?.phase == .armed, song?.index == k {
            let left = target - music.playbackTime
            if left <= 0.02 { break }
            try? await Task.sleep(nanoseconds: UInt64(min(left, 0.25) * 1_000_000_000))
        }
    }

    private func stillArmed(_ k: Int) -> Bool {
        run?.phase == .armed && run?.afterTrack == k && song?.index == k && music.isPlaying
    }

    private func waitUntil(_ deadline: Double, afterTrack k: Int) async {
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard run?.afterTrack == k, run?.cancelled == nil else { return }
            let left = deadline - ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, min(left, 0.05)) * 1_000_000_000))
        }
    }

    private func stopRequested(_ reason: InterludeStopReason?, afterTrack: Int?) {
        let cancel: TalkoverCancel
        switch reason {
        case nil: cancel = .userStop
        case .sourceRevoked?: cancel = .revoked
        case .interruption?: cancel = .interruption
        case .routeRemoved?: cancel = .routeRemoved
        }
        if let afterTrack, let r = run, r.afterTrack != afterTrack, held?.afterTrack != afterTrack { return }
        cancelRun(cancel)
        // A revoke drops the held break: it must not be narrated later in the gap.
        if cancel == .revoked, let h = held, afterTrack == nil || afterTrack == h.afterTrack { drop(h.afterTrack) }
    }

    private func cancelRun(_ reason: TalkoverCancel) {
        guard var r = run, r.cancelled == nil, r.phase != .done else { return }
        let action = r.stopped(reason)
        run = r
        trace(.cancel(reason, r.afterTrack))
        log.notice("\(TalkoverLog.cancel(afterTrack: r.afterTrack, reason), privacy: .public)")
        _ = action // the adapter's own stop already halts a playing clip
        book.retireIfDone()
    }

    private func apply(_ action: TalkoverRun.Action, afterTrack k: Int) {
        switch action {
        case .stopVoice(let fade):
            trace(.cancel(.seekWhileSpeaking, k))
            log.notice("\(TalkoverLog.cancel(afterTrack: k, .seekWhileSpeaking), privacy: .public)")
            if fade { interlude.fadeOutTalkover() } else { interlude.stop() }
        case .abandon(let reason):
            trace(.cancel(reason, k))
            log.notice("\(TalkoverLog.cancel(afterTrack: k, reason), privacy: .public)")
            // Seek back before the voice: the held break still plays in the gap at the end.
        case .none:
            break
        }
    }

    private func drop(_ k: Int) {
        if held?.afterTrack == k { held = nil }
        book.release(key(k))
        djSession.talkoverDropped(afterTrack: k)
    }

    private func decide(_ d: TalkoverDecision, afterTrack k: Int) {
        trace(.decision(d, k))
        log.notice("\(TalkoverLog.decision(afterTrack: k, d), privacy: .public)")
    }

    private var reported: Set<String> = []
    private func reportMisses() {
        guard let r = run else { return }
        for m in r.misses where !reported.contains("\(r.afterTrack)-\(m.rawValue)") {
            reported.insert("\(r.afterTrack)-\(m.rawValue)")
            let seconds = Self.missSeconds(m, r)
            trace(.miss(m, r.afterTrack, seconds))
            log.notice("\(TalkoverLog.miss(afterTrack: r.afterTrack, m, ms: seconds.map { Int($0 * 1000) }), privacy: .public)")
        }
        if reported.count > 64 { reported.removeAll() }
    }

    private static func missSeconds(_ m: TalkoverMiss, _ r: TalkoverRun) -> Double? {
        guard let start = r.voiceStartedAt else { return nil }
        switch m {
        case .nextStartLate, .nextStartEarly:
            guard let at = r.nextAudibleAt, let expected = r.plan.nextAudibleAfterVoice else { return nil }
            return at - (start + expected)
        case .endAfterPlayCue:
            guard let end = r.naturalEndAt, let play = r.plan.nextPlayAfterVoice else { return nil }
            return end - (start + play)
        case .voiceEndedFirst:
            guard let end = r.voiceEndedAt, let expected = r.plan.nextAudibleAfterVoice else { return nil }
            return (start + expected) - end
        case .voiceStartLate, .endedBeforeVoice:
            return nil
        }
    }

    /// DIAG rows. `P0EventTrace` exists only in DEBUG and P0_DIAG builds, so the app passes
    /// plain values and the host builds the row.
    private enum TraceEvent {
        case decision(TalkoverDecision, Int)
        case miss(TalkoverMiss, Int, Double?)
        case cancel(TalkoverCancel, Int)
        case latency(measured: Double, next: Double, Int)
        /// #388: counts and codes only (`StationRatingWithdrawnLines`).
        case ratedNever(StationRatingWithdrawnLines, Int)
        /// Echo's #396 room N1: a held or taken break lost the cues naming an excluded song (counts only).
        case narrowed(ExcludedCueCounts, Int)
    }

    private func trace(_ event: TraceEvent) {
        #if AERODJ_P0_DIAG
        P0EventTraceHost.shared.talkover { trace, t in
            switch event {
            case let .decision(d, k): _ = trace.talkoverDecision(d, afterTrack: k, at: t)
            case let .miss(m, k, seconds): _ = trace.talkoverMiss(m, afterTrack: k, seconds: seconds, at: t)
            case let .cancel(c, k): _ = trace.talkoverCancel(c, afterTrack: k, at: t)
            case let .latency(measured, next, k): _ = trace.talkoverLatency(measured: measured, next: next, afterTrack: k, at: t)
            case let .ratedNever(dropped, k): _ = trace.talkoverRatedNever(dropped, afterTrack: k, at: t)
            case let .narrowed(counts, k): _ = trace.breakNarrowed(counts, afterTrack: k, at: t)
            }
        }
        #endif
    }
}
