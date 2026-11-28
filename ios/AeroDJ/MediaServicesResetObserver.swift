import AVFoundation
import AeroDJCore
import os

/// #195 (-Fry): `AVAudioSession.mediaServicesWereResetNotification`. Runs Core's
/// `MediaServicesResetPlan` on the main actor: stop a speaking or pending break without a fade,
/// drop every voice player so the next break decodes fresh ones, clear the app's activation
/// record, re-apply the normal category, and resume music only when the listener still wants it.
/// Owned by the talk-over coordinator next to `DJRouteChangeObserver`: `start()` adds the
/// observer once, `stop()` and `deinit` remove it. No network.
@MainActor final class MediaServicesResetObserver {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    nonisolated(unsafe) private var token: NSObjectProtocol?

    func start(music: MusicKitService, interlude: InterludePlaybackAdapter) {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                       object: AVAudioSession.sharedInstance(), queue: .main) {
            [weak music, weak interlude] _ in
            MainActor.assumeIsolated {
                guard let music, let interlude else { return }
                Self.apply(music: music, interlude: interlude)
            }
        }
    }

    static func apply(music: MusicKitService, interlude: InterludePlaybackAdapter) {
        let state = interlude.mediaServicesResetBreak
        let plan = MediaServicesResetPlan.plan(break: state, mayAutoResume: music.mayAutoResume)
        log.notice("\(PlaybackLog.mediaServicesReset(break: state, resume: plan.steps.contains(.resumeMusicIfAllowed)), privacy: .public)")
        for step in plan.steps {
            switch step {
            case .stopBreak:
                // The route-removed stop: now, no fade, and it cancels a pending break too.
                interlude.stopCurrentInterlude(reason: .routeRemoved)
            case .rebuildVoicePlayers:
                interlude.discardPlayersAfterMediaServicesReset()
            case .releaseAppActivation:
                TalkoverAudioSession.noteReleased()
            case .reapplyCategory:
                TalkoverAudioSession.restore()
            case .resumeMusicIfAllowed:
                Task { await music.resumeIfAllowed() }
            }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
