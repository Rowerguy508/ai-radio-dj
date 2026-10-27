import Foundation

/// Ordering for a song-row tap: the play request must not wait on DJ break preparation.
///
/// Build 8 (`e7f9003`) awaited `DJBreakSession.queueStarted` before `MusicKitService.play`
/// (`PlaybackActions.swift` MusicSearch.live). When break prep hung (e.g. on-device voice),
/// the song never started, transport never reached `.preparing`, and #109's 8s confirm
/// timeout never armed. Lock-screen remote play then bypassed the app gate by driving
/// `ApplicationMusicPlayer` directly.
///
/// Rule: call `play` first; schedule `queueStarted` (and any intro/break prep) in a
/// cancellable background task. Consent/approved-handoff filtering still runs when the
/// handoff is read, before `queueStarted` receives personal cues.
public enum TapPlayOrdering: Equatable, Sendable {
    /// The song play request runs to completion (or throws) before break prep is scheduled.
    case playThenBackgroundBreakPrep
    /// Legacy build-8 order: await break prep, then play. Must not be used on the tap path.
    case breakPrepThenPlay
}

/// Runs the tap-play sequence. `play` is always awaited first when policy is
/// `.playThenBackgroundBreakPrep`. `breakPrep` is started in a task the caller keeps
/// and cancels on stop / skip / commentary-off / a newer tap.
public enum TapPlaySequence {
    /// Executes `play`, then schedules `breakPrep` in a new `Task` and returns that handle.
    /// Does not await `breakPrep`. Throws only what `play` throws.
    @MainActor
    public static func run(
        policy: TapPlayOrdering = .playThenBackgroundBreakPrep,
        play: @MainActor () async throws -> Void,
        breakPrep: @MainActor @escaping () async -> Void
    ) async throws -> Task<Void, Never> {
        switch policy {
        case .playThenBackgroundBreakPrep:
            try await play()
            return Task { @MainActor in await breakPrep() }
        case .breakPrepThenPlay:
            await breakPrep()
            try await play()
            return Task { @MainActor in }
        }
    }
}

/// Whether a remote / lock-screen play command may start audio.
/// Same gate as `playIfStillAllowed` after `play()` returns: held sessions must pause.
public enum RemotePlayGate {
    public static func admit(mayAutoResume: Bool, userWantsPlayback: Bool) -> PlayReturn {
        PlaybackStartGuard.afterPlay(mayAutoResume: mayAutoResume, userWantsPlayback: userWantsPlayback)
    }
}
