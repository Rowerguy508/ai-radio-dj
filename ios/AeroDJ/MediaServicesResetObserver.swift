import AVFoundation
import AeroDJCore
import os

/// #195 (-Fry): `AVAudioSession.mediaServicesWereResetNotification`. Runs Core's
/// `MediaServicesResetPlan` on the main actor: stop a speaking or pending break without a fade,
/// cancel a talk-over still in its arm/duck window, drop every voice player so the next break
/// decodes fresh ones, clear the app's activation record, re-apply the normal category, and
/// resume music only when the listener still wants it. The app never calls `setActive(true)` for
/// music; the talk-over duck's own activation is released here and redone by the next duck.
/// Owned by the talk-over coordinator next to `DJRouteChangeObserver`: `start()` adds the
/// observer once, `stop()` and `deinit` remove it. No network.
@MainActor final class MediaServicesResetObserver {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    nonisolated(unsafe) private var token: NSObjectProtocol?
    /// Sentinel's N2/N6/N7: one resume at a time (Core's `MediaResetResume`). A cancel only stops
    /// a resume that has not started, so it is silent: never playbackStartRefused, never a banner.
    private let resume = MediaResetResume()

    func start(coordinator: TalkoverCoordinator, music: MusicKitService, interlude: InterludePlaybackAdapter) {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                       object: AVAudioSession.sharedInstance(), queue: .main) {
            [weak self, weak coordinator, weak music, weak interlude] _ in
            MainActor.assumeIsolated {
                guard let self, let coordinator, let music, let interlude else { return }
                self.apply(coordinator: coordinator, music: music, interlude: interlude)
            }
        }
    }

    func apply(coordinator: TalkoverCoordinator, music: MusicKitService, interlude: InterludePlaybackAdapter) {
        let state = interlude.mediaServicesResetBreak
        // Atlas's M2: a speaking talk-over gets the resume (its tail never resumes music).
        let plan = MediaServicesResetPlan.plan(break: state,
                                               talkoverSpeaking: interlude.mediaServicesResetTalkoverSpeaking,
                                               talkoverArmed: coordinator.hasArmedTalkover,
                                               mayAutoResume: music.mayAutoResume)
        Self.log.notice("\(PlaybackLog.mediaServicesReset(break: state, resume: plan.steps.contains(.resumeMusicIfAllowed)), privacy: .public)")
        for step in plan.steps {
            switch step {
            case .stopBreak:
                // The route-removed stop: now, no fade, and it cancels a pending break too.
                // Sentinel's N3: ordering. This halts the clip and resumes the break's continuation,
                // but the break's tail (its one music resume) runs on a later main-actor turn, after
                // this loop has re-applied the category below. Keep this loop synchronous.
                interlude.stopCurrentInterlude(reason: .routeRemoved)
            case .cancelArmedTalkover:
                coordinator.cancelArmedTalkoverAfterMediaReset()
            case .rebuildVoicePlayers:
                interlude.discardPlayersAfterMediaServicesReset()
            case .releaseAppActivation:
                TalkoverAudioSession.noteReleased()
            case .reapplyCategory:
                TalkoverAudioSession.restore()
            case .resumeMusicIfAllowed:
                // Sentinel's N2: coalesced, and skipped while music still plays (no second play()).
                resume.request(isPlaying: { [weak music] in music?.isPlaying ?? true },
                               resume: { [weak music] in await music?.resumeIfAllowed() })
            }
        }
    }

    func stop() {
        resume.cancel()
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    deinit {
        resume.cancel()
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
