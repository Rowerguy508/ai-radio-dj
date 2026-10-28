#if AERODJ_P0_DIAG
// TEMPORARY P0 Experiment B, level 8 (remove with #121 / #133). -Atlas
// Compiled only when the internal TestFlight workflow sets AERODJ_P0_DIAG. Never in App Store builds.
//
// Level 8 = B1-B4 as the REAL app runs them: Play, Resume, Pause and Next go through
// `MusicKitService.shared` (its engine, one-song queue and boundaries, confirm watchdog, #125's
// SelfStartInterruptionGate and AudioSessionPolicy). Direct Mode's own layer stack drives nothing
// at level 8, and S is forced off, so the service is the player's only owner.
// `DirectModePlayPathProbe` is the seam: MusicKitService.swift calls it only inside
// `#if AERODJ_P0_DIAG`, so a build without the flag has no hook code at all. Observe-only: every
// probe call records and returns; nothing reads back into the service.
import AVFoundation
import AeroDJCore
import Foundation
import MusicKit

/// The seam MusicKitService.swift calls. Records only while level 8's host has installed a sink.
enum DirectModePlayPathProbe {
    /// Installed by `DirectModeServicePathHost.start` at level 8 only. Nil: every mark is dropped.
    @MainActor static var sink: (@MainActor (DirectModePlayPathEvent, TimeInterval) -> Void)?

    /// Captures the uptime now, then delivers on the main actor (the interruption observer is not
    /// main-actor). Lines are ordered by that captured time.
    nonisolated static func mark(_ event: DirectModePlayPathEvent) {
        let uptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in sink?(event, uptime) }
    }

    /// From MusicKitService's interruption observer. Reads the type, reason and options numbers
    /// only. `wasSuspended` reads the legacy key by its string value (the constant is deprecated
    /// since iOS 14.5); when absent it is `reason == appWasSuspended`.
    nonisolated static func markInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            let reason = DirectModeInterruptionReason(
                rawReason: note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
            let wasSuspended = note.userInfo?["AVAudioSessionInterruptionWasSuspendedKey"] as? Bool
                ?? (reason == .appWasSuspended)
            mark(.interruptionBegan(reason: reason, wasSuspended: wasSuspended))
        } else if type == .ended {
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            mark(.interruptionEnded(
                shouldResume: AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)))
        }
    }
}

@MainActor
final class DirectModeServicePathHost: ObservableObject {
    @Published private(set) var trace: DirectModePlayPathTrace
    private var openedAt: TimeInterval = 0
    private var engaged = false

    init(level: DirectModeLayerLevel) {
        trace = DirectModePlayPathTrace(level: level)
    }

    var isOn: Bool { trace.isEnabled }

    /// Level 8 only: install the probe's sink. `openedAt` is Direct Mode's clock origin (uptime).
    func start(openedAt: TimeInterval) {
        guard isOn else { return }
        self.openedAt = openedAt
        DirectModePlayPathProbe.sink = { [weak self] event, uptime in
            guard let self else { return }
            self.trace.record(event, at: uptime - self.openedAt)
        }
    }

    func stop() {
        guard isOn else { return }
        DirectModePlayPathProbe.sink = nil
    }

    /// After Direct Mode's own authorization: the service's launch path (`apply(.authorized)`:
    /// category, observers, poll, subscription). Natural ends are handed off as PlayerView does
    /// when no break is prepared: leave the transition, then `startNextTrack`.
    func engage() async {
        guard isOn, !engaged else { return }
        engaged = true
        let service = MusicKitService.shared
        service.onBoundary = { @MainActor [service] boundary, finishedIndex in
            guard case .naturalEnd = boundary else { return }
            service.skipInterlude()
            Task { @MainActor in await service.startNextTrack(after: finishedIndex) }
        }
        await service.refreshAuthorizationStatus()
        trace.record(.serviceEngaged, at: ProcessInfo.processInfo.systemUptime - openedAt)
    }

    /// Play, Resume or Next was tapped (t base for `tap+`).
    func tapped(at t: Double) { trace.tapped(at: t) }

    /// The user's Pause: `MusicKitService.pause()`.
    func pause() { MusicKitService.shared.pause() }

    /// The service's own entry points, exactly as the normal app's buttons call them.
    func perform(_ command: DirectModeCommand, songs: [Song]) async throws {
        let service = MusicKitService.shared
        switch command {
        case .play: try await service.play(songs.map(Track.init(song:)))
        case .resume: try await service.resume()
        case .next: try await service.skip()
        case .pause: service.pause()
        case .load: break  // Direct Mode's load(); then `engage()`

        }
    }
}
#endif
