import Foundation

// DJ talk-over (owner request on #195, -Fry). See docs/dj-talkover.md.
//
// The DJ starts MAIN over the end of the current song (the outro ducks under it), and the
// closing line rides the start of the next song, which swells back up when the voice ends.
//
// The planner and the run state are pure: they take numbers and return numbers or a reason
// code. The app layer (`TalkoverCoordinator`) reads the player, starts the voice and the next
// track, and ducks or unducks the session. Nothing here takes a String, so no title, artist,
// line text or ID reaches a log line.
//
// What we cannot do (platform): `ApplicationMusicPlayer` has no volume API, so the song's
// duck depth and ramp are the system's (`AVAudioSession.CategoryOptions.duckOthers`), not ours.
// MusicKit exposes no intro, vocal-onset or cue metadata, so the intro length is unknown for
// catalog songs. One player plays one song at a time, so the next song can only start after
// the current one has ended.

// MARK: - Flag

/// Default OFF. ON only in the owner A/B TestFlight build (`AERODJ_OWNER_AB`), which the owner
/// asked for on 2026-10-29. In that build a `UserDefaults` bool under `defaultsKey` (the Player
/// toolbar toggle) can turn it off and back on without a new build. In every other build the
/// saved value is ignored (not deleted): a normal build installed over an owner A/B build has no
/// toggle, so a saved ON must not keep it talking over (build 26 QA T-15). Debug, the fixture test
/// station, plain Release and `swift test` are OFF.
public enum DJTalkoverFlag {
    public static let defaultsKey = "AeroDJTalkoverEnabled"

    #if AERODJ_OWNER_AB
    public static let isOwnerABBuild = true
    #else
    public static let isOwnerABBuild = false
    #endif

    /// What an unset toggle shows in the owner A/B build (ON). OFF in every other build.
    public static let buildDefault = isOwnerABBuild

    /// The decision, pure. ON only in an owner A/B build whose saved toggle is ON, or unset with
    /// `unsetDefault` ON. Outside an owner A/B build it is OFF whatever was saved (fail-closed).
    public static func isEnabled(ownerABBuild: Bool, saved: Bool?, unsetDefault: Bool = true) -> Bool {
        guard ownerABBuild else { return false }
        return saved ?? unsetDefault
    }

    /// Reads the saved toggle (never writes or removes it). Pass `ownerABBuild` explicitly in tests.
    public static func isEnabled(defaults: UserDefaults = .standard, ownerABBuild: Bool = DJTalkoverFlag.isOwnerABBuild,
                                 unsetDefault: Bool = true) -> Bool {
        isEnabled(ownerABBuild: ownerABBuild, saved: defaults.object(forKey: defaultsKey) as? Bool,
                  unsetDefault: unsetDefault)
    }
}

// MARK: - Inputs

/// The break's voice, as measured from the decoded clips (not the estimate).
///
/// `talkOverStartSeconds` and `talkOverSeconds` are Echo's hook on `PreparedDJBreak`
/// (radio-style, PR #209): when the closing line's audio starts, measured
/// from the start of the break (MAIN length plus Echo's 0.3 s speech gap), and the closing
/// clip's length. Nil when the break has no `.talkOver` closing line, when it was dropped, or
/// when its clip failed to render or decode: then the closing line is not timed against the
/// next song and everything after the outro plays in the gap.
public struct TalkoverVoice: Equatable, Sendable {
    public var totalSeconds: Double
    public var talkOverStartSeconds: Double?
    public var talkOverSeconds: Double?

    public init(totalSeconds: Double, talkOverStartSeconds: Double? = nil, talkOverSeconds: Double? = nil) {
        self.totalSeconds = totalSeconds
        self.talkOverStartSeconds = talkOverStartSeconds
        self.talkOverSeconds = talkOverSeconds
    }

    /// The closing line, when it is usable: start and length are finite and positive, and it
    /// ends no later than the voice (0.25 s slack for rounding between clip and hook).
    public var closing: (start: Double, length: Double)? {
        guard let s = talkOverStartSeconds, let l = talkOverSeconds,
              s.isFinite, l.isFinite, s > 0, l > 0, s + l <= totalSeconds + 0.25 else { return nil }
        return (s, l)
    }
}

/// The playing song, as the player sees it now.
public struct TalkoverTrack: Equatable, Sendable {
    /// Catalog duration (`Song.duration`). Nil: unknown, hard break.
    public var duration: Double?
    /// `ApplicationMusicPlayer.playbackTime` now.
    public var position: Double
    public init(duration: Double?, position: Double) {
        self.duration = duration
        self.position = position
    }
    public var remaining: Double? {
        guard let duration, duration.isFinite, position.isFinite else { return nil }
        return duration - position
    }
}

/// Tunables. Defaults are the proposal in docs/dj-talkover.md; the device run tunes them.
public struct TalkoverConfig: Equatable, Sendable {
    /// Longest outro the DJ talks over.
    public var maxOutroOverlap: Double = 6
    /// Below this it is not worth ducking: hard break.
    public var minOutroOverlap: Double = 2
    /// Songs shorter than this never get a talk-over (interludes, skits, short edits).
    public var minTrackSeconds: Double = 60
    /// The outro overlap is at most this share of the song.
    public var maxOutroShare: Double = 0.1
    /// Next songs shorter than this never get the closing line over their intro.
    public var minNextTrackSeconds: Double = 60
    /// The planner must decide at least this long before the voice starts (take the break,
    /// decode, set the session). A seek that lands closer to the end is a hard break.
    public var armLead: Double = 1.5
    /// Longest break the talk-over handles. Echo's approved budget: MAIN about 15 s, the 0.3 s
    /// gap, a closing line about 3 s, so about 18.5 s; 20 leaves slack for rendering.
    public var maxVoiceSeconds: Double = 20
    /// Longest closing line we let ride an intro of unknown length.
    public var maxClosingSeconds: Double = 4
    /// `ApplicationMusicPlayer` start latency: from `startNextTrack` to audible. The next
    /// track's play() is called this early so its audio lands with the closing line.
    public var startLatency: Double = 0.8
    /// Clamp for a measured latency fed back from the device.
    public var startLatencyRange: ClosedRange<Double> = 0.3...2.0
    /// A voice start later than this against the plan is a timing miss.
    public var voiceStartTolerance: Double = 0.5
    /// A next-track start this far from its target is a timing miss.
    public var nextStartTolerance: Double = 1.0

    public init() {}

    /// Latency for the next plan: the measured value smoothed into the current one, clamped.
    public func updatedLatency(current: Double, measured: Double, weight: Double = 0.3) -> Double {
        guard measured.isFinite, measured > 0 else { return current }
        let next = current * (1 - weight) + measured * weight
        return min(max(next, startLatencyRange.lowerBound), startLatencyRange.upperBound)
    }
}

// MARK: - Echo seam

extension PreparedDJBreak {
    /// The voice the planner sees, from Echo's hook (#209): `talkOverStartSeconds` (every clip
    /// before the closing line plus the 0.3 s speech gap) and `talkOverSeconds` (the closing
    /// clip). Both nil when there is no closing line or it was dropped: the break then plans
    /// `.outroOnly` (or a hard break) and the closing line, if any, plays in the gap. The clips
    /// do not carry the gap, so the total is start + closing, not `measuredSeconds`.
    public var talkoverVoice: TalkoverVoice {
        if let start = talkOverStartSeconds, let closing = talkOverSeconds {
            return TalkoverVoice(totalSeconds: start + closing, talkOverStartSeconds: start, talkOverSeconds: closing)
        }
        return TalkoverVoice(totalSeconds: measuredSeconds)
    }
}

/// Which clips the talk-over plays, after the app decoded them. MAIN may come from a cloud
/// voice and the closing line from the on-device voice (Sentinel: the closing line carries the
/// next song's attribution and is gated on its own), so either can fail on its own.
public enum TalkoverClips {
    public struct Resolved: Equatable, Sendable {
        /// Leading clips to play, in order.
        public var count: Int
        /// The voice to plan with (closing line removed when it is not played).
        public var voice: TalkoverVoice
        /// Silence before the closing clip, so it starts at `talkOverStartSeconds` even when
        /// the clips do not carry Echo's 0.3 s gap themselves. 0 without a closing line.
        public var closingGap: Double
        public var droppedClosing: Bool
    }

    /// `decoded` is each clip's decoded length, nil for a clip that failed to decode or has no
    /// audio. Any failed MAIN clip: nil (the whole break is skipped, as today). A failed
    /// closing clip: MAIN only, no talk-over of the intro, MAIN still plays in the gap.
    public static func resolve(decoded: [Double?], voice: TalkoverVoice) -> Resolved? {
        guard !decoded.isEmpty else { return nil }
        let hasClosing = voice.closing != nil && decoded.count >= 2
        let mainCount = hasClosing ? decoded.count - 1 : decoded.count
        let main = decoded.prefix(mainCount)
        guard main.allSatisfy({ ($0 ?? 0) > 0 }) else { return nil }
        let mainSeconds = main.reduce(0) { $0 + ($1 ?? 0) }
        guard hasClosing, let closing = voice.closing, let closingSeconds = decoded.last ?? nil, closingSeconds > 0 else {
            return Resolved(count: mainCount, voice: TalkoverVoice(totalSeconds: mainSeconds),
                            closingGap: 0, droppedClosing: voice.closing != nil)
        }
        let gap = min(max(closing.start - mainSeconds, 0), 1.0)
        let start = mainSeconds + gap
        return Resolved(count: decoded.count,
                        voice: TalkoverVoice(totalSeconds: start + closingSeconds,
                                             talkOverStartSeconds: start, talkOverSeconds: closingSeconds),
                        closingGap: gap, droppedClosing: false)
    }
}

// MARK: - Plan

public enum TalkoverMode: String, Equatable, Sendable {
    /// Outro ducks under MAIN; the next song starts under the closing line and swells as it ends.
    case outroAndIntro
    /// Outro ducks under MAIN; the rest of the voice plays in the gap; the next song starts
    /// after the voice, as today.
    case outroOnly
}

/// Why the planner fell back to today's hard break (voice in the gap, song after it).
public enum TalkoverHardBreak: String, Equatable, Sendable, CaseIterable {
    case flagOff
    case durationUnknown
    case trackTooShort
    case voiceTooLong
    case voiceInvalid
    /// Too little time left to arm before the outro window (late seek, late ready break).
    case tooLateToArm
    /// The clamps leave less than `minOutroOverlap`.
    case outroTooShort
    /// The song ended (or was cut) before the voice started.
    case endedBeforeVoice
}

/// Why the closing line did not get the intro (the plan is `.outroOnly`).
public enum TalkoverIntroSkip: String, Equatable, Sendable, CaseIterable {
    case noClosingLine
    case closingTooLong
    case nextTrackTooShort
    case nextTrackUnknown
    /// A known intro (never for catalog songs today) is shorter than the closing line.
    case introTooShort
}

public struct TalkoverPlan: Equatable, Sendable {
    public var mode: TalkoverMode
    /// Why the intro half was skipped (`.outroOnly` only).
    public var introSkip: TalkoverIntroSkip?
    /// Seconds of the current song the voice talks over.
    public var outroOverlap: Double
    /// Song time at which the voice starts (= duration − outroOverlap).
    public var voiceStartAt: Double
    /// Seconds after the voice starts to call the next track's play(). Nil: after the voice.
    public var nextPlayAfterVoice: Double?
    /// Seconds after the voice starts that the next song is expected to be audible.
    public var nextAudibleAfterVoice: Double?
    /// Seconds after the voice starts that the session is released (unduck, the swell starts).
    public var unduckAfterVoice: Double
    /// Latency the plan budgeted.
    public var startLatency: Double
    public var voiceSeconds: Double
}

public enum TalkoverDecision: Equatable, Sendable {
    case talkover(TalkoverPlan)
    case hardBreak(TalkoverHardBreak)

    public var plan: TalkoverPlan? { if case .talkover(let p) = self { p } else { nil } }
}

public enum TalkoverPlanner {
    /// One decision for the break after the playing song.
    ///
    /// Timing model (song time t, voice time v from the voice's first sample):
    /// - voice start: t = duration − O, where O = min(maxOutro, share × duration, voice length,
    ///   remaining − armLead). O < minOutro → hard break.
    /// - next play(): v = talkOverStartSeconds − startLatency, so the song is audible as the
    ///   closing line starts. One player: the current song must have ended by then, so
    ///   O ≤ talkOverStartSeconds − startLatency (MAIN covers the outro).
    /// - unduck: v = voice length (the swell starts as the closing line ends).
    /// - no usable closing line → `.outroOnly`: the next song starts after the voice.
    public static func decide(flag: Bool, track: TalkoverTrack, voice: TalkoverVoice,
                              nextTrackDuration: Double?, introLength: Double? = nil,
                              config: TalkoverConfig = TalkoverConfig()) -> TalkoverDecision {
        guard flag else { return .hardBreak(.flagOff) }
        guard let duration = track.duration, duration.isFinite, duration > 0,
              let remaining = track.remaining else { return .hardBreak(.durationUnknown) }
        guard voice.totalSeconds.isFinite, voice.totalSeconds > 0 else { return .hardBreak(.voiceInvalid) }
        guard duration >= config.minTrackSeconds else { return .hardBreak(.trackTooShort) }
        guard voice.totalSeconds <= config.maxVoiceSeconds else { return .hardBreak(.voiceTooLong) }
        guard remaining > 0 else { return .hardBreak(.endedBeforeVoice) }

        let latency = min(max(config.startLatency, config.startLatencyRange.lowerBound), config.startLatencyRange.upperBound)
        // The intro half first: it can lower the outro cap.
        var introSkip: TalkoverIntroSkip?
        var closing = voice.closing
        if closing == nil {
            introSkip = .noClosingLine
        } else if let c = closing, c.length > config.maxClosingSeconds {
            introSkip = .closingTooLong
        } else if let next = nextTrackDuration, !(next.isFinite && next >= config.minNextTrackSeconds) {
            introSkip = .nextTrackTooShort
        } else if nextTrackDuration == nil {
            introSkip = .nextTrackUnknown
        } else if let intro = introLength, let c = closing, intro < c.length + 0.5 {
            introSkip = .introTooShort
        }
        if introSkip != nil { closing = nil }

        var cap = min(config.maxOutroOverlap, duration * config.maxOutroShare, voice.totalSeconds,
                      remaining - config.armLead)
        if let c = closing { cap = min(cap, c.start - latency) }
        if remaining - config.armLead < config.minOutroOverlap { return .hardBreak(.tooLateToArm) }
        // With a closing line that leaves MAIN too short to cover the outro, drop the intro half
        // rather than the whole talk-over.
        if cap < config.minOutroOverlap, closing != nil {
            closing = nil
            introSkip = .closingTooLong
            cap = min(config.maxOutroOverlap, duration * config.maxOutroShare, voice.totalSeconds,
                      remaining - config.armLead)
        }
        guard cap >= config.minOutroOverlap else { return .hardBreak(.outroTooShort) }
        let outro = (cap * 10).rounded(.down) / 10

        if let c = closing {
            let play = max(outro, c.start - latency)
            return .talkover(TalkoverPlan(mode: .outroAndIntro, introSkip: nil, outroOverlap: outro,
                                          voiceStartAt: duration - outro, nextPlayAfterVoice: play,
                                          nextAudibleAfterVoice: play + latency,
                                          unduckAfterVoice: voice.totalSeconds, startLatency: latency,
                                          voiceSeconds: voice.totalSeconds))
        }
        return .talkover(TalkoverPlan(mode: .outroOnly, introSkip: introSkip, outroOverlap: outro,
                                      voiceStartAt: duration - outro, nextPlayAfterVoice: nil,
                                      nextAudibleAfterVoice: nil, unduckAfterVoice: voice.totalSeconds,
                                      startLatency: latency, voiceSeconds: voice.totalSeconds))
    }

    /// When to take the break and arm the voice: `armLead` before the earliest possible voice
    /// start. Song time; nil when the duration is unknown.
    public static func armAt(duration: Double?, config: TalkoverConfig = TalkoverConfig()) -> Double? {
        guard let duration, duration.isFinite else { return nil }
        return duration - config.maxOutroOverlap - config.armLead
    }
}

// MARK: - Run

/// Timing misses, logged as codes with milliseconds. A miss never stops the music.
public enum TalkoverMiss: String, Equatable, Sendable, CaseIterable {
    /// The voice started later than planned (`voiceStartTolerance`).
    case voiceStartLate
    /// The song ended before the voice could start: that break plays as a hard break.
    case endedBeforeVoice
    /// The next song became audible later than planned.
    case nextStartLate
    /// The next song became audible earlier than planned.
    case nextStartEarly
    /// The natural end came after the planned play() time (catalog duration short).
    case endAfterPlayCue
    /// The voice ended before the next song was audible (a short gap, like today).
    case voiceEndedFirst
}

/// What ended a talk-over before the plan finished.
public enum TalkoverCancel: String, Equatable, Sendable, CaseIterable {
    case seekOutOfWindow
    case seekWhileSpeaking
    /// `onSongSkipped`: the song was cut.
    case skip
    /// The untagged break stop: a user pause, a skip, or a new queue (the service sends nil
    /// for all three).
    case userStop
    case interruption
    case routeRemoved
    case revoked
    /// The voice could not start (session, duck or player refused).
    case voiceFailed
}

/// One talk-over's lifecycle for the break after `afterTrack`, as a pure state machine.
/// Times are seconds on one monotonic clock (system uptime).
public struct TalkoverRun: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Planned; the voice has not started.
        case armed
        /// The voice is playing over the outro or in the gap.
        case speaking(since: Double)
        /// The voice ended or was cancelled; the boundary may still be pending.
        case done
    }

    public enum Action: Equatable, Sendable {
        /// Stop the voice now (fade it out first when `fade` is true) and release the session.
        case stopVoice(fade: Bool)
        /// The talk-over is over without a break; the natural end hands over normally.
        case abandon(TalkoverCancel)
        case none
    }

    public let afterTrack: Int
    public private(set) var plan: TalkoverPlan
    public private(set) var phase: Phase = .armed
    public private(set) var cancelled: TalkoverCancel?
    public private(set) var naturalEndAt: Double?
    public private(set) var nextCalledAt: Double?
    public private(set) var nextAudibleAt: Double?
    public private(set) var voiceEndedAt: Double?
    public private(set) var misses: [TalkoverMiss] = []

    public init(afterTrack: Int, plan: TalkoverPlan) {
        self.afterTrack = afterTrack
        self.plan = plan
    }

    public var voiceStartedAt: Double? {
        if case .speaking(let s) = phase { return s }
        return startedAt
    }
    private var startedAt: Double?

    public var isSpeaking: Bool { if case .speaking = phase { true } else { false } }

    /// The voice really started (AVAudioPlayer.play() returned true). `songPosition` is the
    /// song time at that moment; a late start is a miss.
    public mutating func voiceStarted(at now: Double, songPosition: Double, config: TalkoverConfig = TalkoverConfig()) {
        guard phase == .armed else { return }
        phase = .speaking(since: now)
        startedAt = now
        if songPosition - plan.voiceStartAt > config.voiceStartTolerance { misses.append(.voiceStartLate) }
    }

    /// The voice ended on its own.
    public mutating func voiceFinished(at now: Double) {
        guard isSpeaking else { return }
        phase = .done
        voiceEndedAt = now
        if plan.mode == .outroAndIntro, nextAudibleAt == nil { misses.append(.voiceEndedFirst) }
    }

    /// The user seeked to `position` in the playing song. Before the voice: a seek out of the
    /// outro window aborts the pending talk-over (it is re-planned when the song gets there
    /// again). While speaking over the outro: the voice stops with a short fade and the break
    /// is dropped (it was written for this boundary and is not replayed).
    public mutating func userSeeked(to position: Double, config: TalkoverConfig = TalkoverConfig()) -> Action {
        switch phase {
        case .armed:
            guard position < plan.voiceStartAt - config.armLead else { return .none }
            return cancel(.seekOutOfWindow, stop: false)
        case .speaking:
            guard naturalEndAt == nil else { return .none } // the song is already over
            return cancel(.seekWhileSpeaking, stop: true, fade: true)
        case .done:
            return .none
        }
    }

    /// Skip, pause or new queue (`userStop`), interruption, route removal, consent revoke, failed voice.
    /// The existing break stop hook already halts the clip; this records it and asks the
    /// coordinator to release the session if the voice was audible.
    public mutating func stopped(_ reason: TalkoverCancel) -> Action {
        switch phase {
        case .armed: return cancel(reason, stop: false)
        case .speaking: return cancel(reason, stop: true, fade: false)
        case .done: return .none
        }
    }

    /// The song ended on its own at `now`. Returns how long the boundary should wait before
    /// calling the next track's play() (0 = now). Not speaking yet: the song beat the voice;
    /// the talk-over is abandoned and the break plays as a hard break.
    public mutating func naturalEnd(at now: Double) -> (waitSeconds: Double, abandoned: Bool) {
        naturalEndAt = now
        switch phase {
        case .armed:
            misses.append(.endedBeforeVoice)
            cancelled = nil
            phase = .done
            return (0, true)
        case .done:
            return (0, false)
        case .speaking(let since):
            guard let play = plan.nextPlayAfterVoice else {
                // `.outroOnly`: the next song waits for the voice (the boundary awaits it).
                return (max(0, since + plan.voiceSeconds - now), false)
            }
            let target = since + play
            if now > target + 0.05 { misses.append(.endAfterPlayCue) }
            return (max(0, target - now), false)
        }
    }

    /// The boundary called the next track's play().
    public mutating func nextPlayCalled(at now: Double) { nextCalledAt = now }

    /// The next song was first seen playing. Returns the measured start latency.
    @discardableResult
    public mutating func nextAudible(at now: Double, config: TalkoverConfig = TalkoverConfig()) -> Double? {
        guard nextAudibleAt == nil else { return nil }
        nextAudibleAt = now
        if let since = startedAt, let expected = plan.nextAudibleAfterVoice {
            let delta = now - (since + expected)
            if delta > config.nextStartTolerance { misses.append(.nextStartLate) }
            if delta < -config.nextStartTolerance { misses.append(.nextStartEarly) }
        }
        guard let called = nextCalledAt else { return nil }
        return now - called
    }

    private mutating func cancel(_ reason: TalkoverCancel, stop: Bool, fade: Bool = false) -> Action {
        cancelled = reason
        phase = .done
        return stop ? .stopVoice(fade: fade) : .abandon(reason)
    }
}

// MARK: - Bookkeeping across boundaries

/// Which boundaries the talk-over owns, and the one run in flight. Pure, so "arms once per
/// launch" and "a stale index after a queue swap suppresses a break" are tested on Linux.
///
/// Keys are the song's queue index plus its track ID: a new queue restarts indices at 0, so an
/// index alone would collide with the old queue's.
public struct TalkoverBook: Equatable, Sendable {
    public struct Key: Hashable, Sendable {
        public let index: Int
        public let trackID: String
        public init(index: Int, trackID: String) {
            self.index = index
            self.trackID = trackID
        }
    }

    /// Boundaries this coordinator took the break for; the binder skips its own hand-out.
    public private(set) var owned: Set<Key> = []
    /// The talk-over in flight. Retired on every terminal path (see `retireIfDone`).
    public var run: TalkoverRun? {
        didSet { if run == nil || oldValue == nil { runFromOldQueue = false } }
    }
    /// The run in flight belongs to a queue that was since replaced or refilled (Atlas #210,
    /// 6503808131). Its indices mean nothing in the new queue, and its next song's start can
    /// never be measured, so it retires as soon as its voice ends.
    public private(set) var runFromOldQueue = false
    public private(set) var lastStarted: Key?

    public init() {}

    public func owns(_ key: Key) -> Bool { owned.contains(key) }

    /// A talk-over may arm for `key`: not already owned, and no run in flight.
    public func mayArm(_ key: Key) -> Bool {
        guard !owned.contains(key) else { return false }
        guard let r = run else { return true }
        // A finished run for an earlier boundary, or from an old queue, never blocks this one.
        return r.phase == .done && (runFromOldQueue || r.afterTrack < key.index)
    }

    public mutating func claim(_ key: Key) { owned.insert(key) }

    /// The boundary for `key` resolved (played, fell back, skipped, dropped).
    public mutating func release(_ key: Key) {
        owned.remove(key)
        retireIfDone()
    }

    /// Retires a finished run. A run stays only while its voice is audible or armed, or while
    /// its next song's start is still to be measured (`nextPlayCalled` without `nextAudible`).
    /// A run from an old queue retires unconditionally: no sample is taken, L is unchanged.
    public mutating func retireIfDone() {
        guard let r = run, r.phase == .done else { return }
        if !runFromOldQueue, r.nextCalledAt != nil, r.nextAudibleAt == nil, r.cancelled == nil { return }
        run = nil
    }

    /// Song `key` really started. Returns true when it started a new queue (index went back, or
    /// the same index holds another track): everything owned belonged to the old queue.
    @discardableResult
    public mutating func songStarted(_ key: Key) -> Bool {
        defer { lastStarted = key }
        let replaced = isReplacement(key)
        if replaced {
            owned.removeAll()
            if let r = run, !r.isSpeaking { run = nil }
            if run != nil { runFromOldQueue = true } // still speaking: retire when the voice ends
        } else {
            owned = owned.filter { $0.index >= key.index }
            // The same song started again (a tap on it, a restart): its boundary is fresh.
            if key == lastStarted {
                owned.remove(key)
                if let r = run, r.afterTrack == key.index, !r.isSpeaking { run = nil }
            }
            // Song k+1 started: the latency sample (if any) was taken before this call.
            if let r = run, r.afterTrack < key.index, r.nextCalledAt != nil, r.nextAudibleAt == nil, !r.isSpeaking {
                run = nil
            }
        }
        retireIfDone()
        return replaced
    }

    /// Song `key` starting would begin a new queue (a replacement or a refill): its index went
    /// back, or the same index holds another track. A latency sample is never taken across one.
    public func isReplacement(_ key: Key) -> Bool {
        guard let last = lastStarted else { return false }
        return key.index < last.index || (key.index == last.index && key.trackID != last.trackID)
    }

    /// The user skipped song `key`: its boundary never comes.
    public mutating func songSkipped(_ key: Key) {
        owned.remove(key)
        if let r = run, r.afterTrack == key.index {
            var copy = r
            _ = copy.stopped(.skip)
            run = copy
        }
        retireIfDone()
    }
}

/// The session's own report around the talk-over duck activation (DIAG only, codes only).
/// `otherBefore`/`hintBefore`: `isOtherAudioPlaying` / `secondaryAudioShouldBeSilencedHint`
/// before `setActive(true)`; `otherAfter`/`hintAfter` right after. See docs/dj-talkover.md.
public struct TalkoverDuckProbe: Equatable, Sendable {
    public var otherBefore: Bool
    public var hintBefore: Bool
    public var activated: Bool
    public var otherAfter: Bool
    public var hintAfter: Bool

    public init(otherBefore: Bool, hintBefore: Bool, activated: Bool, otherAfter: Bool, hintAfter: Bool) {
        self.otherBefore = otherBefore
        self.hintBefore = hintBefore
        self.activated = activated
        self.otherAfter = otherAfter
        self.hintAfter = hintAfter
    }
}

// MARK: - Loudness (mixed voices)

/// MAIN may be a cloud voice and the closing line on-device (Sentinel's per-cue gate), so two
/// clips in one break can differ in loudness. Each clip gets a gain that brings its measured
/// RMS to a common target. Attenuate only: the gain never exceeds 1 (AVAudioPlayer.volume
/// cannot boost), so the louder clip comes down to the quieter one within `maxCut`.
public enum TalkoverLoudness {
    public static let targetDBFS: Float = -20
    public static let maxCutDB: Float = 9

    /// Per-clip linear gain (0...1). A nil or silent reading keeps that clip at 1.
    public static func gains(rmsDBFS: [Float?], target: Float = targetDBFS, maxCut: Float = maxCutDB) -> [Float] {
        let known = rmsDBFS.compactMap { $0 }.filter { $0.isFinite && $0 > -70 }
        guard !known.isEmpty else { return rmsDBFS.map { _ in 1 } }
        // The common level: the target, but never above the quietest clip (no boost exists).
        let level = min(target, known.min()!)
        return rmsDBFS.map { value in
            guard let value, value.isFinite, value > -70 else { return 1 }
            let cut = min(max(value - level, 0), maxCut)
            return powf(10, -cut / 20)
        }
    }

    /// RMS in dBFS of interleaved or mono float samples. -inf for silence or empty input.
    public static func rmsDBFS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 0 ? Float(20 * log10(rms)) : -.infinity
    }
}

// MARK: - Log lines

/// Log-safe lines (codes, seconds with one decimal, milliseconds). No text, no IDs.
public enum TalkoverLog {
    private static func s(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "-" }
        return String(format: "%.1f", v)
    }

    public static func decision(afterTrack k: Int, _ d: TalkoverDecision) -> String {
        switch d {
        case .hardBreak(let r):
            return "talkover plan after=\(k) result=hardBreak reason=\(r.rawValue)"
        case .talkover(let p):
            return "talkover plan after=\(k) result=\(p.mode.rawValue) intro=\(p.introSkip?.rawValue ?? "used")"
                + " outro=\(s(p.outroOverlap)) voice=\(s(p.voiceSeconds)) play=\(s(p.nextPlayAfterVoice))"
                + " unduck=\(s(p.unduckAfterVoice)) lat=\(Int((p.startLatency * 1000).rounded()))"
        }
    }

    public static func miss(afterTrack k: Int, _ m: TalkoverMiss, ms: Int?) -> String {
        "talkover miss after=\(k) code=\(m.rawValue) ms=\(ms.map(String.init) ?? "-")"
    }

    public static func cancel(afterTrack k: Int, _ c: TalkoverCancel) -> String {
        "talkover cancel after=\(k) reason=\(c.rawValue)"
    }

    public static func latency(afterTrack k: Int, measuredMs: Int, nextMs: Int) -> String {
        "talkover latency after=\(k) measured=\(measuredMs) next=\(nextMs)"
    }
}
