// TEMPORARY build 9 no-audio diagnostics.
// Delete this file and every call tagged "TEMPORARY build 9 diagnostics" once the
// device cause is known. Removal is tracked in the PR
// "P0: tapped song stays paused at 0:00 (build 9)".
//
// Privacy: enum names, booleans, counts, NSError domain and code, and
// localizedDescription of a thrown error. Never a title, an id, the query,
// a storefront, or subscription details. The overlay has no controls and ignores touches.

import AeroDJCore
@preconcurrency import MusicKit
import SwiftUI

/// Who last called pause or stop. Diagnostic only.
enum PlaybackStopCaller: String, Equatable {
    case userPause
    case confirmFailed
    case afterPlayHeld
    case pollHeld
    case breakPause
    case skipAtEnd
    case sessionSuspend
}

/// The last session notice, reduced to an enum. Diagnostic only.
enum SessionNoticeKind: String, Equatable {
    case interruptionBegan
    case interruptionEnded
    case routeOldDeviceUnavailable
    case routeOther

    init(_ notice: AudioSessionNotice) {
        switch notice {
        case .interruptionBegan: self = .interruptionBegan
        case .interruptionEnded: self = .interruptionEnded
        case .routeChanged(.oldDeviceUnavailable): self = .routeOldDeviceUnavailable
        case .routeChanged(.other): self = .routeOther
        }
    }
}

@MainActor
final class P0TapDiagnostics: ObservableObject {
    static let shared = P0TapDiagnostics()

    struct Reading: Equatable {
        var transport: String
        var playerStatus: String
        var canPlayCatalog: String
        var lastStop: String
        var lastNotice: String
        var lastError: String
    }

    @Published private(set) var reading: Reading?
    @Published private(set) var canPlayCatalog = "unknown"
    @Published private(set) var lastStop = "none"
    @Published private(set) var lastNotice = "none"
    @Published private(set) var lastError = "none"
    @Published private(set) var waiting = false

    private var readingTask: Task<Void, Never>?

    func markTap(
        transport: @escaping @MainActor () -> String,
        playerStatus: @escaping @MainActor () -> String
    ) {
        reading = nil
        lastError = "none"
        waiting = true
        readingTask?.cancel()
        readingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.waiting = false
            self.reading = Reading(
                transport: transport(),
                playerStatus: playerStatus(),
                canPlayCatalog: self.canPlayCatalog,
                lastStop: self.lastStop,
                lastNotice: self.lastNotice,
                lastError: self.lastError)
        }
    }

    func setCanPlayCatalog(_ value: Bool) {
        canPlayCatalog = value ? "true" : "false"
    }

    func noteStop(_ caller: PlaybackStopCaller) {
        lastStop = caller.rawValue
    }

    func noteSession(_ kind: SessionNoticeKind) {
        lastNotice = kind.rawValue
    }

    /// Domain, code, and localizedDescription. Nothing else from the error.
    func noteThrown(_ error: Error) {
        let ns = error as NSError
        lastError = "\(ns.domain) \(ns.code). \(ns.localizedDescription)"
    }

    static func statusName(_ status: MusicKit.MusicPlayer.PlaybackStatus) -> String {
        switch status {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        case .seekingForward: "seekingForward"
        case .seekingBackward: "seekingBackward"
        @unknown default: "unknown"
        }
    }
}

/// TEMPORARY build 9 diagnostics. Read-only text. No buttons. Ignores touches.
struct P0TapDiagnosticsOverlay: View {
    @ObservedObject private var diagnostics = P0TapDiagnostics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TEMPORARY build 9 diagnostics").bold()
            if let reading = diagnostics.reading {
                Text("transport=\(reading.transport) playbackStatus=\(reading.playerStatus)")
                Text("canPlayCatalogContent=\(reading.canPlayCatalog)")
                Text("lastStop=\(reading.lastStop)")
                Text("lastNotice=\(reading.lastNotice)")
                Text("error=\(reading.lastError)")
            } else if diagnostics.waiting {
                Text("reading at 3 s…")
                Text("canPlayCatalogContent=\(diagnostics.canPlayCatalog)")
                Text("lastStop=\(diagnostics.lastStop)")
                Text("lastNotice=\(diagnostics.lastNotice)")
                Text("error=\(diagnostics.lastError)")
            } else {
                Text("tap a song")
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.yellow)
        .padding(6)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
        .padding(4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
