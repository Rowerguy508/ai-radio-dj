#if AERODJ_P0_DIAG
// TEMPORARY P0 diagnostics: on-screen playback event trace (remove with #121 / #133). -Fry
// Compiled only when the internal TestFlight workflow sets AERODJ_P0_DIAG. Never in App Store builds.
//
// The single app-side owner of Core `P0EventTrace`. The service and the boundary closure call
// one-line hooks; this file observes the audio session interruption and app lifecycle notices
// itself. Rows are sanitized by Core (enums, booleans, counts, rounded seconds, codes only).
// Each row is also written to the system log (subsystem com.aerodj.app, category p0trace).
import AVFoundation
import AeroDJCore
import OSLog
import SwiftUI
import UIKit

@MainActor
final class P0EventTraceHost: ObservableObject {
    static let shared = P0EventTraceHost()

    /// Oldest first, at most `P0EventTrace.capacity`.
    @Published private(set) var rows: [P0TraceRow] = []
    /// The last 3 polls, recorded on every poll even when nothing changed. Oldest first.
    @Published private(set) var lastPolls: [P0TraceRow] = []
    /// The build line, then the last 3 polls (pinned, so a stuck state shows in one screenshot).
    @Published private(set) var header: String
    /// No source SHA is embedded in the app, so the build number is the identifier.
    private let buildLine: String

    private var trace = P0EventTrace()
    private let launchUptime = ProcessInfo.processInfo.systemUptime
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.aerodj.app", category: "p0trace")

    private init() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        buildLine = "p0_diag build \(build.flatMap(Int.init).map(String.init) ?? "-")"
        header = buildLine
    }

    /// Seconds since launch on the monotonic uptime clock.
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime - launchUptime }

    func clear() {
        trace.clear()
        publish()
    }

    private func publish() {
        rows = trace.rows
        lastPolls = trace.lastPolls
        header = ([buildLine] + trace.lastPolls.map(\.rendered)).joined(separator: "\n")
    }

    /// Called once from `AeroDJApp.init`. Observes interruptions and app lifecycle notices.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            let reasonRaw = info?[AVAudioSessionInterruptionReasonKey] as? UInt
            let began = type == .began
            let shouldResume = began ? nil : options.map { $0.contains(.shouldResume) }
            MainActor.assumeIsolated {
                let host = P0EventTraceHost.shared
                let audio = host.sessionAudio()
                let reason = reasonRaw.map(Self.reason)
                host.apply { _ = $0.interruption(began: began, shouldResume: shouldResume, reason: reason,
                                             audio: audio, at: $1) }
            }
        })
        let lifecycle: [(Notification.Name, P0EventTrace.Lifecycle)] = [
            (UIApplication.willResignActiveNotification, .willResignActive),
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
        ]
        for (name, notice) in lifecycle {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    P0EventTraceHost.shared.apply { _ = $0.appLifecycle(notice, at: $1) }
                }
            })
        }
    }

    // MARK: Hooks (one line at each call site)

    func beginPoll(_ observation: PlaybackObservation, before: P0DetectorState, queueIndex: Int, queueCount: Int) {
        apply { _ = $0.beginPoll(observation, before: before, queueIndex: queueIndex, queueCount: queueCount, at: $1) }
    }

    func endPoll(_ step: BoundaryStep?, after: P0DetectorState) {
        apply { trace, _ in _ = trace.endPoll(step, after: after) }
    }

    func sessionNotice(_ notice: AudioSessionNotice, gate: SelfStartInterruptionGate.Decision) {
        let audio = sessionAudio()
        apply { _ = $0.sessionNotice(notice, gate: gate, audio: audio, at: $1) }
    }

    /// Other-audio state at the moment a notice is handled. Booleans only.
    func sessionAudio() -> P0EventTrace.SessionAudio {
        let session = AVAudioSession.sharedInstance()
        return P0EventTrace.SessionAudio(otherAudio: session.isOtherAudioPlaying,
                                         secondaryHint: session.secondaryAudioShouldBeSilencedHint)
    }

    /// `AVAudioSessionInterruptionReasonKey` as the trace's enum. 1 is the deprecated
    /// appWasSuspended, compared by raw value so the build has no deprecation warning.
    nonisolated static func reason(_ raw: UInt) -> P0EventTrace.InterruptionReason {
        if raw == 1 { return .appWasSuspended }
        switch AVAudioSession.InterruptionReason(rawValue: raw) {
        case .default?: return .default
        case .builtInMicMuted?: return .builtInMicMuted
        case .routeDisconnected?: return .routeDisconnected
        default: return .unknown
        }
    }

    func onBoundary(_ boundary: PlaybackBoundary, finishedIndex: Int) {
        apply { _ = $0.onBoundary(boundary, finishedIndex: finishedIndex, at: $1) }
    }

    func naturalBoundary(_ result: P0EventTrace.BreakResult, afterTrack: Int) {
        apply { _ = $0.naturalBoundary(result, afterTrack: afterTrack, at: $1) }
    }

    func startNextTrack(_ stage: P0EventTrace.NextStage, after index: Int, queueCount: Int, gates: P0EventTrace.Gates) {
        apply { _ = $0.startNextTrack(stage, after: index, queueCount: queueCount, gates: gates, at: $1) }
    }

    func startTrack(_ outcome: P0EventTrace.StartOutcome, index: Int, queueCount: Int, userInitiated: Bool,
                    gates: P0EventTrace.Gates) {
        apply { _ = $0.startTrack(outcome, index: index, queueCount: queueCount, userInitiated: userInitiated,
                              gates: gates, at: $1) }
    }

    func remoteGatePause(queueIndex: Int, queueCount: Int, gates: P0EventTrace.Gates) {
        apply { _ = $0.remoteGatePause(queueIndex: queueIndex, queueCount: queueCount, gates: gates, at: $1) }
    }

    func scenePhase(_ phase: ScenePhase) {
        let mapped: P0EventTrace.Phase
        switch phase {
        case .active: mapped = .active
        case .inactive: mapped = .inactive
        case .background: mapped = .background
        @unknown default: mapped = .inactive
        }
        apply { _ = $0.scenePhase(mapped, at: $1) }
    }

    /// DJ talk-over rows (`TalkoverCoordinator`): decisions, misses, cancels, latency. Codes only.
    func talkover(_ body: (inout P0EventTrace, TimeInterval) -> Void) {
        apply(body)
    }

    private func apply(_ body: (inout P0EventTrace, TimeInterval) -> Void) {
        let before = trace.rows.last?.id
        let pollsBefore = trace.lastPolls.last?.id
        let t = now
        body(&trace, t)
        let newRows = trace.rows.last?.id != before
        guard newRows || trace.lastPolls.last?.id != pollsBefore else { return }
        for row in trace.rows where newRows && (before.map({ row.id > $0 }) ?? true) {
            log.notice("\(row.rendered, privacy: .public)")
        }
        publish()
    }
}

/// Records scene phase changes into the trace. Applied at the app root.
struct P0ScenePhaseTrace: ViewModifier {
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onAppear { P0EventTraceHost.shared.scenePhase(phase) }
            .onChange(of: phase) { _, new in P0EventTraceHost.shared.scenePhase(new) }
    }
}

/// The trace on the Player screen. `P0TraceView` is the view (Nova owns that file).
struct P0EventTracePanel: View {
    @ObservedObject private var host = P0EventTraceHost.shared
    /// DJ talk-over rollback switch (-Fry). Unset reads the build default (ON only in the
    /// owner A/B build); flipping it stores an override that wins on the next break.
    @AppStorage(DJTalkoverFlag.defaultsKey) private var talkover = DJTalkoverFlag.buildDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("DJ talk-over", isOn: $talkover)
                .font(.caption.monospaced())
                .accessibilityIdentifier("p0.talkoverToggle")
            P0TraceView(rows: host.rows, header: host.header, onClear: { host.clear() })
        }
    }
}
#endif
