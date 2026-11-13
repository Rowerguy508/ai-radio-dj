@preconcurrency import ActivityKit
import AeroDJCore
import Combine
import Foundation
import OSLog
import UIKit
@preconcurrency import WidgetKit

/// #465 item 7 (-Nova): feeds the Now Playing / StandBy widget and the on-air Live Activity.
///
/// Rules (Echo, Sentinel):
/// - Everything that leaves the app is one `NowPlayingDisplay`: station, track, artist,
///   generated art, playback state, `DJStudioState.onAirLabel` and the Ready line. No script
///   or briefing text, tokens, user ID, consent state or tester_voice data; the type has no
///   field for them. `widgetCopy` drops On Air and Ready before the App Group write.
/// - Never on the playback path. The `$snapshot` and DJ observers only enqueue a value; one
///   background task writes the App Group and talks to ActivityKit. Nothing awaits it, nothing
///   in playback reads it, and every failure is swallowed and logged without identifiers.
/// - Live only, and only when the widget extension is embedded in the app (it isn't until its
///   signing is set up; see the PR). Until then this does nothing at all.
@MainActor
final class NowPlayingSurfaces {
    static let shared = NowPlayingSurfaces()

    private var started = false
    private var watchers = Set<AnyCancellable>()
    private var djTask: Task<Void, Never>?
    private var snapshot = PlaybackSnapshot()
    private var dj: DJStudioState = .idle
    private var continuation: AsyncStream<SurfaceChange>.Continuation?

    /// The extension ships inside the app as PlugIns/AeroDJWidgets.appex.
    static var isWidgetExtensionEmbedded: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("AeroDJWidgets.appex").path)
    }

    func start(_ dependencies: AppDependencies) {
        guard !started, dependencies.mode == .live, Self.isWidgetExtensionEmbedded else { return }
        started = true

        // Latest value wins: a burst of changes collapses into the newest one.
        let (stream, continuation) = AsyncStream<SurfaceChange>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        Task.detached(priority: .utility) {
            await NowPlayingSurfaceWorker.run(stream)
        }

        snapshot = dependencies.playback.snapshot
        dj = dependencies.dj.studioState
        dependencies.playback.$snapshot
            .sink { snapshot in
                Task { @MainActor in NowPlayingSurfaces.shared.snapshotChanged(snapshot) }
            }
            .store(in: &watchers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { _ in
                Task { @MainActor in NowPlayingSurfaces.shared.publish() }
            }
            .store(in: &watchers)
        let store = dependencies.dj
        djTask = Task { @MainActor in
            for await state in store.updates() {
                NowPlayingSurfaces.shared.djChanged(DJStudioState(state))
            }
        }
        publish()
    }

    private func snapshotChanged(_ snapshot: PlaybackSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        publish()
    }

    private func djChanged(_ state: DJStudioState) {
        guard state != dj else { return }
        dj = state
        publish()
    }

    private func publish() {
        let display = NowPlayingDisplay.make(snapshot: snapshot, dj: dj)
        continuation?.yield(SurfaceChange(display: display,
                                          appInForeground: UIApplication.shared.applicationState == .active))
    }
}

/// One published value and whether the app could start a Live Activity right now.
struct SurfaceChange: Sendable {
    let display: NowPlayingDisplay
    let appInForeground: Bool
}

/// The background side. Runs in one detached task, so App Group writes and ActivityKit calls
/// happen in order and never on the main actor. Activities are looked up by type each time
/// rather than stored, so no ActivityKit object crosses an isolation boundary.
enum NowPlayingSurfaceWorker {
    /// Messages are fixed strings plus an error's type name: never an activity ID, push token,
    /// station or song, and never a transaction ID, JWS or appAccountToken.
    private static let log = Logger(subsystem: "com.aerodj.app", category: "surfaces")

    static func run(_ changes: AsyncStream<SurfaceChange>) async {
        await endAll()
        var widgetShown: NowPlayingDisplay?
        var activityShown: NowPlayingDisplay?
        for await change in changes {
            if NowPlayingDisplayStore.needsWidgetReload(from: widgetShown, to: change.display) {
                writeWidget(change.display)
                widgetShown = change.display
            }
            activityShown = await applyLiveActivity(change, previous: activityShown)
        }
    }

    private static func writeWidget(_ display: NowPlayingDisplay) {
        guard let data = NowPlayingDisplayStore.encode(display),
              let defaults = UserDefaults(suiteName: NowPlayingDisplayStore.appGroupID) else {
            log.notice("widget display not written")
            return
        }
        defaults.set(data, forKey: NowPlayingDisplayStore.defaultsKey)
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingDisplayStore.widgetKind)
    }

    /// Returns what the running activity now shows (nil when none is running).
    private static func applyLiveActivity(_ change: SurfaceChange,
                                          previous: NowPlayingDisplay?) async -> NowPlayingDisplay? {
        let current = Activity<OnAirlyActivityAttributes>.activities.first
        let action = LiveActivityPlan.action(for: change.display, previous: current == nil ? nil : previous,
                                             isActive: current != nil,
                                             appInForeground: change.appInForeground,
                                             activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled)
        switch action {
        case .none:
            return current == nil ? nil : previous
        case .start(let display):
            do {
                _ = try Activity<OnAirlyActivityAttributes>.request(
                    attributes: OnAirlyActivityAttributes(),
                    content: ActivityContent(state: display, staleDate: nil),
                    pushType: nil)
                return display
            } catch {
                log.notice("live activity not started: \(String(describing: type(of: error)), privacy: .public)")
                return nil
            }
        case .update(let display):
            await current?.update(ActivityContent(state: display, staleDate: nil))
            return display
        case .end:
            await endAll()
            return nil
        }
    }

    /// Ends every OnAirly activity, including one left over from an earlier launch.
    private static func endAll() async {
        for activity in Activity<OnAirlyActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
