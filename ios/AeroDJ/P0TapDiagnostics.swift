// TEMPORARY P0 diagnostics (remove: #121) -Atlas
// Build 9 no-audio trace. Delete this file and every line tagged "TEMPORARY P0 diagnostics (remove: #121)"
// once the device cause is known; removal is tracked in the PR that added it
// (branch atlas/p0-no-audio-diag).
//
// Privacy (Sentinel): enum names, booleans, counts, raw enum values and error type + code +
// localizedDescription only. Never titles, song/queue IDs, search terms, URLs, storefront or
// subscription details beyond one Bool, String(describing:) of an error, debugDescription
// or userInfo. Read-only: the overlay has no controls and ignores touches.

import AVFoundation
import AeroDJCore
@preconcurrency import MusicKit
import SwiftUI

@MainActor
final class P0TapDiagnostics: ObservableObject {
    static let shared = P0TapDiagnostics()

    /// Frozen 3 s after the latest song tap.
    struct Reading: Equatable {
        var offsetMs: Int
        var transport: String
        var playerStatus: String
        var queueHasEntry: Bool
        var lastPlayError: String
        var lastRefusal: String
        var category: String
        var mode: String
        var otherAudioPlaying: Bool
        var silenceSecondaryHint: Bool
        var canPlayCatalog: String
        var commentary: String
        var speechRenders: Int
        var breaksStarted: Int
    }

    @Published private(set) var log = TapDiagnosticsLog(capacity: 10)
    @Published private(set) var reading: Reading?
    @Published private(set) var lastPlayError = "none"
    @Published private(set) var lastRefusal = "none"
    /// Bool only (MusicSubscription.canPlayCatalogContent); "unknown" until read.
    @Published private(set) var canPlayCatalog = "unknown"
    @Published private(set) var speechRenders = 0
    @Published private(set) var breaksStarted = 0
    /// Set by PlayerView: the station's commentary setting, as its enum name.
    var commentary = "unknown"
    /// Set by PlayerView: index of the station in the app's fixed station list.
    var viewStationIndex = -1

    private var readingTask: Task<Void, Never>?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func markTap(transport: @escaping @MainActor @Sendable () -> String) {
        log.markTap(at: now)
        reading = nil
        lastPlayError = "none"
        lastRefusal = "none"
        record("tap", detail: "station=\(viewStationIndex) commentary=\(commentary)")
        readingTask?.cancel()
        readingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reading = self.read(transport: transport())
        }
    }

    func record(_ tag: StaticString, detail: String = "") {
        log.record(tag, detail: detail, at: now)
    }

    /// Error type + NSError code + localizedDescription, marked TEMPORARY. Nothing else.
    func recordPlayError(_ gate: StaticString, _ error: Error) {
        let text = Self.describe(error)
        lastPlayError = "\(gate): \(text)"
        record(gate, detail: "error")
    }

    /// Which gate last refused or paused a start.
    func recordRefusal(_ gate: StaticString) {
        lastRefusal = "\(gate)"
        record(gate)
    }

    func setCanPlayCatalog(_ value: Bool?) {
        canPlayCatalog = value.map { $0 ? "true" : "false" } ?? "unknown"
    }

    func noteSpeechRenderBegan() {
        speechRenders += 1
        record("speech.render.begin")
    }

    func noteBreakStarted() {
        breaksStarted += 1
        record("break.audio.started")
    }

    static func describe(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        let code = (error as NSError).code
        return "TEMPORARY \(typeName) code \(code). \(error.localizedDescription)"
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

    private func read(transport: String) -> Reading {
        let player = ApplicationMusicPlayer.shared
        let session = AVAudioSession.sharedInstance()
        return Reading(
            offsetMs: log.offsetMs(at: now) ?? -1,
            transport: transport,
            playerStatus: Self.statusName(player.state.playbackStatus),
            queueHasEntry: player.queue.currentEntry != nil,
            lastPlayError: lastPlayError,
            lastRefusal: lastRefusal,
            category: session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""),
            mode: session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""),
            otherAudioPlaying: session.isOtherAudioPlaying,
            silenceSecondaryHint: session.secondaryAudioShouldBeSilencedHint,
            canPlayCatalog: canPlayCatalog,
            commentary: commentary,
            speechRenders: speechRenders,
            breaksStarted: breaksStarted)
    }
}

/// Nonisolated entry point for the speech renderer and the session monitor.
enum P0TapDiagnosticsBridge {
    static func speechRenderBegan() {
        Task { @MainActor in P0TapDiagnostics.shared.noteSpeechRenderBegan() }
    }

    static func record(_ tag: StaticString, detail: String = "") {
        Task { @MainActor in P0TapDiagnostics.shared.record(tag, detail: detail) }
    }
}

/// TEMPORARY P0 diagnostics (remove: #121) -Atlas. Read-only text; no buttons, no gestures, ignores touches.
struct P0TapDiagnosticsOverlay: View {
    @ObservedObject private var diagnostics = P0TapDiagnostics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TEMPORARY P0 diagnostics (remove: #121)").bold()
            if let r = diagnostics.reading {
                Text("@\(r.offsetMs)ms transport=\(r.transport) player=\(r.playerStatus) queueEntry=\(String(r.queueHasEntry))")
                Text("session=\(r.category)/\(r.mode) otherAudio=\(String(r.otherAudioPlaying)) silenceHint=\(String(r.silenceSecondaryHint))")
                Text("canPlayCatalog=\(r.canPlayCatalog) commentary=\(r.commentary)")
                // The commentary split: with commentary off, renders and breaks should stay 0.
                Text("speechRenders=\(r.speechRenders) breaksStarted=\(r.breaksStarted) DJ=\(r.speechRenders + r.breaksStarted == 0 ? "silent" : "active")")
                Text("refused/paused by: \(r.lastRefusal)")
                Text("play error: \(r.lastPlayError)")
            } else {
                Text(diagnostics.log.tapAt == nil ? "tap a song" : "reading at 3 s…")
            }
            ForEach(Array(diagnostics.log.entries.enumerated()), id: \.offset) { _, entry in
                Text("\(entry.offsetMs.map { "+\($0)ms" } ?? "pre-tap") \(entry.tag) \(entry.detail)")
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
