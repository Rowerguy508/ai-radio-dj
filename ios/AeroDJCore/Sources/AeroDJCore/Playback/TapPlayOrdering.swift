import Foundation

/// Ordering for a song-row tap: the play request must not wait on DJ break preparation.
///
/// Build 8 (`e7f9003`) awaited `DJBreakSession.queueStarted` before `MusicKitService.play`
/// (`PlaybackActions.swift` MusicSearch.live). When break prep hung (e.g. on-device voice),
/// the song never started, transport never reached `.preparing`, and #109's 8s confirm
/// timeout never armed. Lock-screen remote play then bypassed the app gate by driving
/// `ApplicationMusicPlayer` directly.
///
/// Rule: call `play` first; then schedule break prep (via the returned / caller-held task).
/// `MusicSearch.live` uses this helper so tests guard the real tap order.
public enum TapPlaySequence {
    /// Awaits `play`, then returns the task from `scheduleBreakPrep` without awaiting it.
    /// Throws only what `play` throws. The live path passes `beginQueueInBackground`.
    @MainActor
    @discardableResult
    public static func run(
        play: @MainActor () async throws -> Void,
        scheduleBreakPrep: @MainActor () -> Task<Void, Never>
    ) async throws -> Task<Void, Never> {
        try await play()
        return scheduleBreakPrep()
    }

    /// #116 (-Atlas): the live order. `reserve` runs synchronously before `play`, so a song
    /// start reported during `play` belongs to the new queue. Then `play`; then break prep is
    /// scheduled without being awaited. If `play` throws, the reservation is released and the
    /// error rethrown. Music still never waits on narration.
    @MainActor
    @discardableResult
    public static func run<Reservation>(
        reserve: @MainActor () -> Reservation,
        play: @MainActor () async throws -> Void,
        scheduleBreakPrep: @MainActor (Reservation) -> Task<Void, Never>,
        release: @MainActor (Reservation) -> Void
    ) async throws -> Task<Void, Never> {
        let reservation = reserve()
        do {
            try await play()
        } catch {
            release(reservation)
            throw error
        }
        return scheduleBreakPrep(reservation)
    }
}

/// Whether a remote / lock-screen play command may start audio.
/// Same gate as `playIfStillAllowed` after `play()` returns: held sessions must pause.
public enum RemotePlayGate {
    public static func admit(mayAutoResume: Bool, userWantsPlayback: Bool) -> PlayReturn {
        PlaybackStartGuard.afterPlay(mayAutoResume: mayAutoResume, userWantsPlayback: userWantsPlayback)
    }
}
