#if AERODJ_P0_DIAG
// TEMPORARY P0 Experiment B: the layer matrix inside the Direct Mode build (remove with #121 / #133).
// Compiled only when the internal TestFlight workflow sets AERODJ_P0_DIAG. Never in App Store builds.
// -Atlas
//
// The selector and the layers' app-side glue. The layer logic itself is `DirectModeLayerStack`
// (AeroDJCore, tested on Linux). DirectModeController stays the ONE caller of the player: it asks
// this host what the enabled layers want and issues it. B4 is the only layer that touches
// AVAudioSession, and only to OBSERVE interruption and route-change notifications: no
// setCategory, no setActive, at any level.
import AVFoundation
import AeroDJCore
import SwiftUI

enum DirectModeLayerSettings {
    /// Diagnostics-only default. Release code never reads it (this file is not compiled there).
    static let levelKey = "p0diag.layerLevel"

    /// Read once per process, at first use (controller init), so a change applies on the next
    /// cold launch. Missing is 0: plain Direct Mode.
    static let levelAtLaunch = DirectModeLayerLevel(stored: UserDefaults.standard.integer(forKey: levelKey))

    /// The level the next cold launch will use.
    static var nextLevel: DirectModeLayerLevel {
        get { DirectModeLayerLevel(stored: UserDefaults.standard.integer(forKey: levelKey)) }
        set { UserDefaults.standard.set(newValue.value, forKey: levelKey) }
    }
}

@MainActor
final class DirectModeLayerHost: ObservableObject {
    @Published private(set) var stack: DirectModeLayerStack
    /// Catalog durations of the loaded songs (B2's near-end signal). Never shown or logged.
    private var durations: [Double?] = []
    private var monitor: DirectModeSessionNoticeMonitor?

    init(level: DirectModeLayerLevel, songCount: Int) {
        stack = DirectModeLayerStack(level: level, songCount: songCount)
    }

    var level: DirectModeLayerLevel { stack.level }

    /// B4 only: observe interruption and route-change notifications, one at a time in arrival
    /// order (the same shape as MusicKitService's monitor). Each directive goes to `issue`.
    func start(clock: @escaping @MainActor () -> Double,
               issue: @escaping @MainActor ([DirectModeLayerAction]) -> Void) {
        guard stack.observesSessionNotifications, monitor == nil else { return }
        let monitor = DirectModeSessionNoticeMonitor()
        self.monitor = monitor
        let events = monitor.events
        Task { @MainActor [weak self] in
            for await notice in events {
                if Task.isCancelled { break }
                guard let self else { return }
                issue(self.stack.handle(notice, at: clock()))
            }
        }
    }

    func stop() {
        monitor = nil
    }

    func loaded(durations: [Double?]) {
        self.durations = durations
    }

    func userCommand(_ command: DirectModeCommand, at t: Double) {
        stack.userCommand(command, at: t)
    }

    func observe(status: DirectModeStatus, position: Double, entryIndex: Int?, at t: Double) -> [DirectModeLayerAction] {
        let index = stack.queueIndex
        let duration = durations.indices.contains(index) ? durations[index] : nil
        return stack.observe(status: status, position: position, duration: duration, entryIndex: entryIndex, at: t)
    }

    func actionFailed(_ action: DirectModeLayerAction, at t: Double) {
        stack.actionFailed(action, at: t)
    }
}

/// Owns the B4 observers off the main actor; its deinit removes them and finishes the stream.
/// Maps notifications exactly as MusicKitService's (private) AudioSessionMonitor does, onto the
/// same Core `AudioSessionNotice`. Reads userInfo only: never the route's port names.
private final class DirectModeSessionNoticeMonitor: NSObject {
    private let eventsStream = FinishingStream<AudioSessionNotice>()
    var events: AsyncStream<AudioSessionNotice> { eventsStream.stream }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .began || type == .ended else { return }
        let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
        eventsStream.yield(.interruption(began: type == .began, shouldResume: shouldResume))
    }

    @objc
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        eventsStream.yield(.routeChange(deviceRemoved: reason == .oldDeviceUnavailable))
    }
}

/// The selector and the layer trace, as a separate panel so DirectModeView changes by two lines.
struct DirectModeLayerPanel: View {
    @ObservedObject var host: DirectModeLayerHost
    @State private var next = DirectModeLayerSettings.nextLevel.value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Experiment B: layers").font(.headline)
            Text("This launch: \(host.level.description)")
                .font(.body.monospaced())
                .accessibilityIdentifier("directMode.layers.current")
            Stepper(value: $next, in: 0...DirectModeLayerLevel.maxWired) {
                Text("Next cold launch: \(DirectModeLayerLevel(stored: next).description)")
                    .font(.body.monospaced())
            }
            .onChange(of: next) { _, value in
                DirectModeLayerSettings.nextLevel = DirectModeLayerLevel(stored: value)
            }
            .accessibilityIdentifier("directMode.layers.next")
            if next != host.level.value {
                Text("Force-quit and relaunch to apply.").font(.caption).foregroundStyle(.orange)
            }
            Text("B5-B7 (break, speech, narration) are not wired in this build.")
                .font(.caption).foregroundStyle(.secondary)
            if !host.level.isOff {
                Text("Transport (B1): \(host.stack.transport.rawValue)").font(.caption.monospaced())
            }
        }
    }

}
#endif
