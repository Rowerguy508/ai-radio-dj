#if AERODJ_P0_DIAG
// TEMPORARY P0 Experiment B, "S" toggle (remove with #121 / #133). -Fry
// Compiled only when the internal TestFlight workflow sets AERODJ_P0_DIAG. Never in App Store builds.
//
// S on: before play(), set `.playback`/`.default` (once) and `setActive(true)`, exactly as
// MusicKitService does at 6171fda; after play(), PlaybackStartGuard; on interruption and
// route-change notices, AudioSessionPolicy; on the poll, RemotePlayGate. Each may pause.
// The decisions are Core `DirectModeSessionLayer`. Orthogonal to the layer level.
// S off (the default): no AVAudioSession call, no observer, no pause.
import AVFoundation
import AeroDJCore
import SwiftUI

enum DirectModeSessionLayerSettings {
    /// Diagnostics-only default. Release code never reads it (this file is not compiled there).
    static let enabledKey = "p0diag.sessionLayer"

    /// Read once per process, so a change applies on the next cold launch. Missing is off.
    static let enabledAtLaunch = UserDefaults.standard.bool(forKey: enabledKey)

    static var nextEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

@MainActor
final class DirectModeSessionLayerHost: ObservableObject {
    @Published private(set) var layer: DirectModeSessionLayer
    private var monitor: DirectModeSessionNoticeMonitor?

    init(enabled: Bool) {
        layer = DirectModeSessionLayer(enabled: enabled)
    }

    var enabled: Bool { layer.enabled }

    /// Observes notices only when S is on. `pause` is the controller's single player.pause().
    func start(clock: @escaping @MainActor () -> Double, pause: @escaping @MainActor () -> Void) {
        guard layer.enabled, monitor == nil else { return }
        let monitor = DirectModeSessionNoticeMonitor()
        self.monitor = monitor
        let events = monitor.events
        Task { @MainActor [weak self] in
            for await notice in events {
                if Task.isCancelled { break }
                guard let self else { return }
                if self.layer.handle(notice, at: clock()) { pause() }
            }
        }
    }

    func stop() {
        monitor = nil
    }

    /// Before play(). Throws the setActive error, as the service does, so play() is not reached.
    func beforePlay(at t: Double) throws {
        guard layer.beforePlay(at: t) else { return }
        let session = AVAudioSession.sharedInstance()
        if layer.needsCategory {
            do {
                try session.setCategory(.playback, mode: .default, options: [])
                layer.categoryResult(ok: true, at: t)
            } catch {
                // The service logs and continues without the category.
                layer.categoryResult(ok: false, at: t)
            }
        }
        do {
            try session.setActive(true)
            layer.activationResult(ok: true, at: t)
        } catch {
            layer.activationResult(ok: false, at: t)
            throw error
        }
    }

    /// After play() returns. True when the controller must pause.
    func afterPlay(at t: Double) -> Bool { layer.afterPlay(at: t) }

    /// The poll saw playing. True when the controller must pause.
    func observePlaying(at t: Double) -> Bool { layer.observePlaying(at: t) }

    func userPause(at t: Double) { layer.userPause(at: t) }
}

struct DirectModeSessionLayerPanel: View {
    @ObservedObject var host: DirectModeSessionLayerHost
    @State private var next = DirectModeSessionLayerSettings.nextEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("S (app session, like build 14): \(host.enabled ? "on" : "off") this launch")
                .font(.body.monospaced())
                .accessibilityIdentifier("directMode.session.current")
            Toggle("Next cold launch: S on", isOn: $next)
                .onChange(of: next) { _, on in DirectModeSessionLayerSettings.nextEnabled = on }
                .accessibilityIdentifier("directMode.session.next")
            if next != host.enabled {
                Text("Force-quit and relaunch to apply.").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
#endif
