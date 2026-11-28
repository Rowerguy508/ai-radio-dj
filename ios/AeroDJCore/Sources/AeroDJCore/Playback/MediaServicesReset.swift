/// #195 (-Fry): what the app does on `AVAudioSession.mediaServicesWereResetNotification`.
///
/// Apple's guidance: after a media services reset every audio object the app holds is invalid.
/// Dispose of and rebuild players and engines, then re-apply the session category. This plan is
/// the order; `MediaServicesResetObserver` in the app runs it on the main actor.
///
/// The app never calls `setActive(true)` for music (MusicKit activates on `play()`), so
/// re-activation is the existing `resumeIfAllowed`, gated by `mayAutoResume`. A break that was
/// speaking or pending is dropped, never replayed: a gap break's stop path already owns the one
/// resume. A speaking talk-over's tail never resumes, so the plan resumes for it (Atlas's M2).

/// The break's state when the reset arrives.
public enum MediaServicesResetBreak: String, Equatable, Sendable {
    case none
    /// A clip player exists and is speaking.
    case speaking
    /// A break is handed out or pending, before any clip player exists.
    case pending
}

public enum MediaServicesResetStep: Equatable, Sendable {
    /// Sentinel's N1: a talk-over armed for this song (the duck window included) that has not
    /// spoken. Cancel the run and release its duck before the players are dropped: the
    /// coordinator's predecoded players are dead and the app's duck record is about to be cleared.
    /// Its held break has not aired, so it still airs once in the gap from the rendered bytes.
    case cancelArmedTalkover
    /// Stop the break now, without a fade: its player is dead. Cancels a pending break too.
    case stopBreak
    /// Drop every voice player the app holds, so the next break builds fresh ones.
    case rebuildVoicePlayers
    /// The app's own activation record is stale after a reset.
    case releaseAppActivation
    /// Re-apply the app's normal category (on an inactive session this activates nothing).
    case reapplyCategory
    /// Music again, only if the listener still wants playback.
    case resumeMusicIfAllowed
}

public struct MediaServicesResetPlan: Equatable, Sendable {
    public let steps: [MediaServicesResetStep]

    public var dropsBreak: Bool { steps.contains(.stopBreak) }

    /// `talkoverSpeaking` (Atlas's M2): the speaking break is a talk-over over playing music.
    /// Its tail never resumes music, so the reset owns the one resume, after the stop.
    /// Sentinel's N14/N15: the speaking break is this song's talk-over: a clip is speaking, the
    /// adapter holds a duck, and the duck is for the track the break is about. Read before the stop.
    public static func isTalkoverSpeaking(clipSpeaking: Bool, breakTrack: Int, duckedFor: Int?) -> Bool {
        clipSpeaking && duckedFor != nil && duckedFor == breakTrack
    }

    public static func plan(break state: MediaServicesResetBreak, talkoverSpeaking: Bool = false,
                            talkoverArmed: Bool = false, mayAutoResume: Bool) -> MediaServicesResetPlan {
        var steps: [MediaServicesResetStep] = []
        if state != .none { steps.append(.stopBreak) }
        if talkoverArmed { steps.append(.cancelArmedTalkover) }
        steps += [.rebuildVoicePlayers, .releaseAppActivation, .reapplyCategory]
        let ownsResume = state == .none || (state == .speaking && talkoverSpeaking)
        if ownsResume, mayAutoResume { steps.append(.resumeMusicIfAllowed) }
        return MediaServicesResetPlan(steps: steps)
    }
}

extension PlaybackLog {
    /// One log-safe line per reset. No track, no user data.
    public static func mediaServicesReset(break state: MediaServicesResetBreak, resume: Bool) -> String {
        "session media services reset break=\(state.rawValue) resume=\(resume)"
    }
}

/// #195 N2/N6/N7 (-Fry): the one music resume after a media services reset.
///
/// One at a time: a second reset while one is pending replaces it. N11: a reset while one is
/// running queues exactly one more pass (any number of resets mid-resume make one rerun), which
/// re-checks `isPlaying` first, so music is not left silent until Play. Cancelling (a newer reset, `stop()`, `deinit`) only stops a resume that has
/// not started. A started resume runs in its own unstructured task, which does not inherit
/// cancellation, so `play()` never sees a CancellationError and a cancel can never surface as
/// `playbackStartRefused` or an error banner. A cancelled resume is silent.
@MainActor
public final class MediaResetResume {
    nonisolated(unsafe) private var task: Task<Void, Never>?
    private var generation = 0
    public private(set) var isInFlight = false
    /// N11: a reset arrived while a resume was running. The newest closures win.
    private var rerun: (isPlaying: @MainActor () -> Bool, resume: @MainActor () async -> Void)?

    public init() {}

    public var isPending: Bool { task != nil && !isInFlight }

    public func request(isPlaying: @escaping @MainActor () -> Bool, resume: @escaping @MainActor () async -> Void) {
        if isInFlight {
            rerun = (isPlaying, resume)
            return
        }
        task?.cancel()
        rerun = nil
        generation += 1
        let mine = generation
        task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, mine == self.generation else { return }
            defer { if mine == self.generation { self.task = nil } }
            var pass: (isPlaying: @MainActor () -> Bool, resume: @MainActor () async -> Void)? = (isPlaying, resume)
            while let current = pass {
                pass = nil
                guard !current.isPlaying() else { break }
                self.isInFlight = true
                // Not a child: a cancel of the outer task never reaches `resume()` once it started.
                await Task { @MainActor in await current.resume() }.value
                self.isInFlight = false
                // A cancel (stop(), deinit) drops the queued pass; it stays silent.
                guard !Task.isCancelled, mine == self.generation else { self.rerun = nil; break }
                pass = self.rerun
                self.rerun = nil
            }
            self.isInFlight = false
        }
    }

    /// Thread-safe (`Task.cancel` is), so `deinit` of a main-actor owner may call it.
    nonisolated public func cancel() {
        task?.cancel()
    }
}
