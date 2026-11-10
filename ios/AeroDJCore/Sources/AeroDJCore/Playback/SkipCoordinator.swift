import Foundation

/// What one step of a skip did to the player.
public enum SkipAdvanceOutcome: Equatable, Sendable {
    /// The song this step loaded is audible.
    case playing
    /// The skip walked off the end of the queue on purpose. Playback is stopped.
    case queueStopped
    /// The load returned and the player is not audible (MusicKit cleared it, or `play()` failed).
    case notPlaying
    /// The user paused, or a newer start owns the player. Do not reload and do not advance.
    case stopChain
}

/// One load inside a skip chain. `.advance` cuts the current song and loads the next.
/// `.reload` loads the song already selected again, after MusicKit cleared that load.
public enum SkipJob: Equatable, Sendable {
    case advance
    case reload
}

/// #444 (-Echo): lock-screen Next can arrive again while `MusicKitService.skip()` is still
/// awaiting `play()`, and MusicKit's own Next can clear the song that load just queued.
///
/// Two `skip()` bodies at once both call `play()` on the shared player, and the second clear
/// (the new song has not played 2 s) is a failed start: `StartFailurePolicy` sends `.userPaused`
/// and the MusicKit queue is already empty, so nothing resumes.
///
/// One chain runs at a time. A second request while it is in flight stores exactly one more
/// advance. A third is ignored. A clear of the song being loaded reloads that song when no
/// further advance is waiting, and never pauses.
@MainActor
public final class SkipCoordinator {
    /// What `requestAdvance()` tells the caller to do.
    public enum Intake: Equatable, Sendable {
        /// This caller starts `runChain`. Nobody else is skipping.
        case begin
        /// A chain is running and no follow-up was stored yet. Do not load and do not pause.
        case queueOneMore
        /// A follow-up is already stored, or this chain has already begun its one follow-up.
        case ignore
    }

    public private(set) var isInFlight = false
    private var chainRunning = false
    private var queued = false
    /// The one follow-up has started. Further advances wait until this chain finishes.
    private var sealed = false
    /// MusicKit cleared the song the current job is loading.
    private var loadCut = false

    public init() {}

    /// A lock-screen Next, the in-app Skip button, or a real mid-song remote skip
    /// (the song had already played). The second one while a chain is running queues one
    /// advance. The third is ignored.
    public func requestAdvance() -> Intake {
        if !isInFlight {
            isInFlight = true
            queued = false
            sealed = false
            return .begin
        }
        if sealed || queued { return .ignore }
        queued = true
        return .queueOneMore
    }

    /// The song being loaded was cleared or rewound before it played (`takeSkipLoadCut`).
    /// The chain reloads it, unless a follow-up advance is already the thing that will play.
    public func noteLoadCut() {
        guard isInFlight else { return }
        loadCut = true
    }

    /// No chain is running, but the song a skip just loaded was cut before it played.
    /// The caller starts `runChain(first: .reload)` so the player is not left paused.
    public func beginRecovery() -> Bool {
        guard !isInFlight, !chainRunning else { return false }
        isInFlight = true
        queued = false
        sealed = false
        loadCut = false
        return true
    }

    /// Runs the skip chain. Only the caller that received `.begin` or `beginRecovery()`
    /// may enter, and a second entry while it is running does nothing.
    /// `body` is the existing skip load (`MusicKitService.skip`'s one advance, or a reload
    /// of the song already selected). A `requestAdvance()` or `noteLoadCut()` during `body`
    /// is picked up when that load returns.
    public func runChain(first: SkipJob = .advance,
                         _ body: @MainActor (SkipJob) async -> SkipAdvanceOutcome) async {
        guard !chainRunning else { return }
        chainRunning = true
        isInFlight = true
        defer {
            chainRunning = false
            isInFlight = false
            queued = false
            sealed = false
            loadCut = false
        }
        var job = first
        var didReload = false
        while true {
            // A cut noted before this load started belongs to the previous song.
            loadCut = false
            let outcome = await body(job)
            let cut = loadCut
            switch outcome {
            case .stopChain, .queueStopped:
                return
            case .playing, .notPlaying:
                let audible = outcome == .playing && !cut
                if queued && !sealed {
                    queued = false
                    sealed = true
                    didReload = false
                    job = .advance
                    continue
                }
                if audible { return }
                // The song we meant to play is not audible. Load it again once.
                // A follow-up that was already sealed stays on that song: reloading it
                // does not walk to a third track.
                if !didReload {
                    didReload = true
                    job = .reload
                    continue
                }
                return
            }
        }
    }
}
