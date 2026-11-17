#if DEBUG
import AVFoundation
import AeroDJCore
import MusicKit
import OSLog
import SwiftUI

// #526 S0a (-Echo): DEBUG-only AirPlay duck spike. Release does not compile this file. The only
// entry is the "Developer (DEBUG)" row in Settings, shown in live DEBUG builds only. No setting,
// launch argument, URL or default reaches it. Device: NOT TESTED.
//
// One run: with Apple Music playing on AirPlay and no DJ break on air, set one session shape
// (`AirPlayDuckSpikeVariant`), activate it, play ONE 2 s test tone with ONE player, release the
// session (`.notifyOthersOnDeactivation`), put today's normal category back, and log what the music
// did. It never pauses, resumes or skips the music itself, and never runs during a break.

@MainActor
final class AirPlayDuckSpikeRunner: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false

    private let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    private var player: AVAudioPlayer?
    private var finishedOK: Bool?
    private var interruptionBegan = false
    private var interruptionEnded = false
    private var routeChanges: [String] = []

    func run(_ variant: AirPlayDuckSpikeVariant) async {
        var report = AirPlayDuckSpikeReport(variant: variant)
        let music = MusicKitService.shared
        let session = AVAudioSession.sharedInstance()
        report.routeBefore = Self.ports(session)
        let remaining = music.currentDuration.map { $0 - music.playbackTime }
        // Never two voices: no DJ break on air or handed out, no talk-over holding the session,
        // no other spike run, and far enough from the song's end that no break can start mid-run.
        let djIdle = music.audioState == .music && !TalkoverAudioSession.appActivated
        if let refusal = AirPlayDuckSpikeGate.refusal(
            running: running, onAirPlay: report.routeBefore.contains(.airPlay),
            musicPlaying: ApplicationMusicPlayer.shared.state.playbackStatus == .playing,
            djIdle: djIdle, remainingSeconds: remaining) {
            report.refusal = refusal
            publish(report)
            return
        }
        running = true
        defer { running = false }
        finishedOK = nil
        interruptionBegan = false
        interruptionEnded = false
        routeChanges = []
        let tokens = observe(session)
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        report.musicBefore = Self.status(ApplicationMusicPlayer.shared.state.playbackStatus)
        report.systemMusicBefore = Self.status(SystemMusicPlayer.shared.state.playbackStatus)

        let config = variant.config
        let policy: AVAudioSession.RouteSharingPolicy = config.policy == .longFormAudio ? .longFormAudio : .default
        var options: AVAudioSession.CategoryOptions = []
        if config.options.contains(.mixWithOthers) { options.insert(.mixWithOthers) }
        if config.options.contains(.duckOthers) { options.insert(.duckOthers) }
        do {
            try session.setCategory(.playback, mode: .default, policy: policy, options: options)
            report.setCategoryOK = true
        } catch {
            log.error("S0a setCategory failed code=\((error as NSError).code, privacy: .public)")
        }
        let activateStart = ProcessInfo.processInfo.systemUptime
        if report.setCategoryOK {
            do {
                try session.setActive(true)
                report.setActiveOK = true
            } catch {
                log.error("S0a setActive failed code=\((error as NSError).code, privacy: .public)")
            }
            report.activateMs = Int((ProcessInfo.processInfo.systemUptime - activateStart) * 1000)
        }
        report.otherAudioPlaying = session.isOtherAudioPlaying
        report.silenceHint = session.secondaryAudioShouldBeSilencedHint
        report.routeDuring = Self.ports(session)

        if report.setActiveOK, let clip = try? AVAudioPlayer(data: AirPlayDuckSpikeClip.toneWAV()) {
            clip.delegate = self
            player = clip
            report.clipStarted = clip.play()
            if report.clipStarted {
                // Sample the music every 200 ms while the one clip plays (max 4 s).
                let limit = ProcessInfo.processInfo.systemUptime + AirPlayDuckSpikeClip.seconds + 2
                while finishedOK == nil, ProcessInfo.processInfo.systemUptime < limit {
                    report.musicDuring.append(Self.status(ApplicationMusicPlayer.shared.state.playbackStatus))
                    report.systemMusicDuring.append(Self.status(SystemMusicPlayer.shared.state.playbackStatus))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            report.clipFinishedOK = finishedOK
        }
        // The clip is stopped before the session is released, so it can never play over the music.
        player?.delegate = nil
        player?.stop()
        player = nil

        var deactivateFailed = false
        if report.setActiveOK {
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                deactivateFailed = true
                let code = (error as NSError).code
                log.error("\(AirPlayDuckSpikeTeardown.deactivateFailedLog(code: code), privacy: .public)")
            }
        }
        // Today's normal category, only on an inactive session (as `DJRouteSession.endGapBreak`).
        // If setActive(false) threw, skip the restore so we don't re-category a live session.
        if AirPlayDuckSpikeTeardown.shouldRestoreCategory(deactivateFailed: deactivateFailed) {
            do {
                let normal: AVAudioSession.CategoryOptions = AppAudioSessionConfig.mixesWithOthers ? [.mixWithOthers] : []
                try session.setCategory(.playback, mode: .default, policy: .default, options: normal)
                report.restoreOK = true
            } catch {
                log.error("S0a restore failed code=\((error as NSError).code, privacy: .public)")
            }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        report.musicAfter = Self.status(ApplicationMusicPlayer.shared.state.playbackStatus)
        report.routeAfter = Self.ports(session)
        report.interruptionBegan = interruptionBegan
        report.interruptionEnded = interruptionEnded
        report.routeChangeReasons = routeChanges
        publish(report)
    }

    private func publish(_ report: AirPlayDuckSpikeReport) {
        for line in report.lines {
            log.notice("\(line, privacy: .public)")
            lines.append(line)
        }
    }

    private func observe(_ session: AVAudioSession) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                              queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue { self.interruptionBegan = true }
                if raw == AVAudioSession.InterruptionType.ended.rawValue { self.interruptionEnded = true }
            }
        }
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                       queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routeChanges.append(raw.map { "r\($0)" } ?? "r?") }
        }
        return [interruption, route]
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishedOK = flag }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finishedOK = false }
    }

    /// Port TYPES only (Sentinel's #526 privacy note): never a port name, UID or device name.
    private static func ports(_ session: AVAudioSession) -> [LongFormPortType] {
        session.currentRoute.outputs.map { output in
            switch output.portType {
            case .airPlay: .airPlay
            case .bluetoothA2DP: .bluetoothA2DP
            case .bluetoothLE: .bluetoothLE
            case .bluetoothHFP: .bluetoothHFP
            case .carAudio: .carAudio
            case .builtInSpeaker: .builtInSpeaker
            case .builtInReceiver: .builtInReceiver
            case .headphones: .headphones
            case .usbAudio: .usbAudio
            case .HDMI: .hdmi
            case .lineOut: .lineOut
            default: .other
            }
        }
    }

    private static func status(_ status: MusicPlayer.PlaybackStatus) -> String {
        switch status {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        case .seekingForward, .seekingBackward: "seeking"
        @unknown default: "unknown"
        }
    }
}

/// The spike's screen: one button per variant, the log lines, and Copy.
struct AirPlayDuckSpikeView: View {
    @StateObject private var runner = AirPlayDuckSpikeRunner()

    var body: some View {
        Form {
            Section {
                Text("DEBUG only. Start a station on an AirPlay speaker, then run one variant at a time. The DJ never speaks during a run. If the music stops, press Play.")
                    .font(.footnote)
            }
            Section("Run once") {
                ForEach(AirPlayDuckSpikeVariant.allCases, id: \.self) { variant in
                    Button("Run \(variant.rawValue)") { Task { await runner.run(variant) } }
                        .disabled(runner.running)
                        .accessibilityIdentifier("s0a.run.\(variant.rawValue)")
                }
            }
            Section("Log") {
                ForEach(Array(runner.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Copy log") { UIPasteboard.general.string = runner.lines.joined(separator: "\n") }
                    .disabled(runner.lines.isEmpty)
            }
        }
        .navigationTitle("S0a AirPlay duck spike")
    }
}
#endif
