#if AERODJ_P0_DIAG
// TEMPORARY P0 Experiment A: MusicKit Direct Mode (remove with #121 / #133) -Atlas
// Compiled only when the internal TestFlight workflow sets AERODJ_P0_DIAG. Never in App Store builds.
//
// The ONE type that sets the queue or calls play / pause / skip in Direct Mode. No DJ prep,
// no watchdog, no auto-skip, no auto-resume, no AVAudioSession configuration or activation:
// ApplicationMusicPlayer owns its session. The poll below only reads state; it issues nothing.
import AVFoundation
import AeroDJCore
@preconcurrency import MusicKit
import SwiftUI

enum DirectModeLaunch {
    /// Set by the Direct Mode screen. Consumed on the next launch, so the launch after that
    /// is Direct Mode again.
    static let normalOnceKey = "AeroDJP0NormalAppOnce"
    /// Long literal so CI can prove presence in diag builds and absence in all others.
    static let buildMarker = "AERODJ_P0_DIAG_DIRECT_MODE_BUILD"

    /// True when this launch should open Direct Mode.
    static func takeLaunchChoice() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: normalOnceKey) else { return true }
        defaults.removeObject(forKey: normalOnceKey)
        return false
    }
}

enum DirectModeSongs {
    /// Public Apple Music catalog song IDs (US storefront), checked against the iTunes lookup
    /// API on 2026-10-27. Song A plays first; "Next song" skips to song B. Not shown or logged.
    static let ids: [MusicItemID] = ["1488408568", "1544494392"]
    /// Loud from 0:00 (-Fry): public US catalog song ID, checked against the iTunes lookup API
    /// on 2026-10-28. Not shown or logged.
    static let loudIntroID: MusicItemID = "726416473"

    static func ids(for set: DirectModeSongSet) -> [MusicItemID] {
        switch set {
        case .standard: return ids
        case .loudFirst: return [loudIntroID, ids[0]]
        }
    }
}

@MainActor
final class DirectModeController: ObservableObject {
    @Published private(set) var machine = DirectModeMachine(songCount: DirectModeSongs.ids.count)
    /// How many of the hard-coded IDs the catalog lookup returned (nil before load).
    @Published private(set) var lookupFound: Int?

    private let player = ApplicationMusicPlayer.shared
    private let openedAt = ProcessInfo.processInfo.systemUptime
    private var loadedIDs: [MusicItemID] = []
    private var pollTask: Task<Void, Never>?
    private var lastSubscriptionRead: Double = -.infinity
    private var audioObservers: [NSObjectProtocol] = []

    private var now: Double { ProcessInfo.processInfo.systemUptime - openedAt }

    func start() {
        guard pollTask == nil else { return }
        observeAudioSessionNotifications()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.observe()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        audioObservers.forEach(NotificationCenter.default.removeObserver)
        audioObservers = []
    }

    /// Before Load only; the queue is set once.
    func selectSongSet(_ set: DirectModeSongSet) { machine.selectSongSet(set, at: now) }

    /// The tester heard the song.
    func markHeard() { machine.markHeard(at: now) }

    // MARK: - Commands (the only callers of ApplicationMusicPlayer commands)

    func load() {
        guard machine.request(.load, at: now) else { return }
        Task {
            do {
                if MusicAuthorization.currentStatus == .notDetermined {
                    _ = await MusicAuthorization.request()
                }
                machine.observeAuthorization(Self.authorization(MusicAuthorization.currentStatus), at: now)
                guard MusicAuthorization.currentStatus == .authorized else {
                    throw DirectModeError.notAuthorized
                }
                let ids = DirectModeSongs.ids(for: machine.songSet)
                var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: ids)
                request.limit = ids.count
                let response = try await request.response()
                let byID = Dictionary(response.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let ordered = ids.compactMap { byID[$0] }
                lookupFound = ordered.count
                guard ordered.count == ids.count else {
                    throw DirectModeError.catalogLookupIncomplete
                }
                loadedIDs = ordered.map(\.id)
                player.queue = ApplicationMusicPlayer.Queue(for: ordered)
                machine.finished(.load, error: nil, at: now)
            } catch {
                machine.finished(.load, error: PlaybackErrorCode(error), at: now)
            }
        }
    }

    func play() { run(.play) }
    func resume() { run(.resume) }
    func next() { run(.next) }

    func pause() {
        guard machine.request(.pause, at: now) else { return }
        player.pause()
        machine.finished(.pause, error: nil, at: now)
    }

    private func run(_ command: DirectModeCommand) {
        guard machine.request(command, at: now) else { return }
        Task {
            do {
                try await perform(command)
                machine.finished(command, error: nil, at: now)
            } catch {
                machine.finished(command, error: PlaybackErrorCode(error), at: now)
            }
        }
    }

    /// Main-actor method (same pattern as MusicKitService) so the player is never sent
    /// across isolation inside a closure.
    private func perform(_ command: DirectModeCommand) async throws {
        switch command {
        case .play, .resume: try await player.play()
        case .next: try await player.skipToNextEntry()
        case .load, .pause: break  // handled by load() and pause()
        }
    }

    // MARK: - Observation only

    private func observe() async {
        let t = now
        machine.observe(status: Self.status(player.state.playbackStatus),
                        position: player.playbackTime,
                        entryIndex: currentEntryIndex(), at: t)
        machine.observeAuthorization(Self.authorization(MusicAuthorization.currentStatus), at: t)
        machine.observeRoute(Self.route(AVAudioSession.sharedInstance().currentRoute), at: t)
        machine.observeAudio(Self.audioSample(AVAudioSession.sharedInstance()), at: t)
        if t - lastSubscriptionRead >= 5 {
            lastSubscriptionRead = t
            let subscription = try? await MusicSubscription.current
            machine.observeCanPlayCatalog(subscription?.canPlayCatalogContent, at: now)
        }
    }

    /// Index of the current entry among the loaded songs; nil when it is anything else.
    private func currentEntryIndex() -> Int? {
        guard !loadedIDs.isEmpty else { return nil }
        let sighting: DirectModeEntrySighting
        if let entry = player.queue.currentEntry {
            switch entry.item {
            case nil: sighting = .itemPending
            case let .song(song)?: sighting = .song(loadedIndex: loadedIDs.firstIndex(of: song.id))
            case .some: sighting = .notSong
            }
        } else {
            sighting = .noEntry
        }
        return sighting.entryIndex(keeping: machine.entryIndex)
    }

    // MARK: - Audio-session probe (-Fry). Reads and notifications only; never a session call.

    private func observeAudioSessionNotifications() {
        guard audioObservers.isEmpty else { return }
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ map: @escaping @Sendable ([AnyHashable: Any]?) -> DirectModeAudioEvent?) {
            audioObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let event = map(note.userInfo) else { return }
                MainActor.assumeIsolated { self?.machine.observeAudioEvent(event, at: self?.now ?? 0) }
            })
        }
        on(AVAudioSession.interruptionNotification) { info in
            guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            switch type {
            case .began:
                return .interruptionBegan(Self.interruptionReason(info?[AVAudioSessionInterruptionReasonKey] as? UInt))
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                return .interruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return nil
            }
        }
        on(AVAudioSession.routeChangeNotification) { info in
            .routeChange(Self.routeChangeReason(info?[AVAudioSessionRouteChangeReasonKey] as? UInt))
        }
        on(AVAudioSession.silenceSecondaryAudioHintNotification) { info in
            let raw = info?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt ?? 0
            return .silenceSecondaryAudioHint(begin: AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) == .begin)
        }
        on(AVAudioSession.mediaServicesWereLostNotification) { _ in .mediaServicesLost }
        on(AVAudioSession.mediaServicesWereResetNotification) { _ in .mediaServicesReset }
    }

    static func audioSample(_ session: AVAudioSession) -> DirectModeAudioSample {
        DirectModeAudioSample(outputVolume: Double(session.outputVolume),
                              route: route(session.currentRoute),
                              category: category(session.category),
                              mode: mode(session.mode),
                              otherAudioPlaying: session.isOtherAudioPlaying,
                              secondaryAudioShouldBeSilenced: session.secondaryAudioShouldBeSilencedHint,
                              outputLatencySeconds: session.outputLatency)
    }

    static func category(_ category: AVAudioSession.Category) -> DirectModeSessionCategory {
        switch category {
        case .soloAmbient: return .soloAmbient
        case .ambient: return .ambient
        case .playback: return .playback
        case .playAndRecord: return .playAndRecord
        case .record: return .record
        case .multiRoute: return .multiRoute
        default: return .other
        }
    }

    static func mode(_ mode: AVAudioSession.Mode) -> DirectModeSessionMode {
        switch mode {
        case .default: return .default
        case .moviePlayback: return .moviePlayback
        case .spokenAudio: return .spokenAudio
        case .voiceChat: return .voiceChat
        case .videoChat: return .videoChat
        case .gameChat: return .gameChat
        case .videoRecording: return .videoRecording
        case .measurement: return .measurement
        case .voicePrompt: return .voicePrompt
        default: return .other
        }
    }

    nonisolated static func interruptionReason(_ raw: UInt?) -> DirectModeInterruptionReason {
        guard let raw else { return .none }
        switch AVAudioSession.InterruptionReason(rawValue: raw) {
        case .default?: return .default
        case .appWasSuspended?: return .appWasSuspended
        case .builtInMicMuted?: return .builtInMicMuted
        case .routeDisconnected?: return .routeDisconnected
        default: return .other
        }
    }

    nonisolated static func routeChangeReason(_ raw: UInt?) -> DirectModeRouteChangeReason {
        switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
        case .unknown?, nil: return .unknown
        case .newDeviceAvailable?: return .newDeviceAvailable
        case .oldDeviceUnavailable?: return .oldDeviceUnavailable
        case .categoryChange?: return .categoryChange
        case .override?: return .override
        case .wakeFromSleep?: return .wakeFromSleep
        case .noSuitableRouteForCategory?: return .noSuitableRouteForCategory
        case .routeConfigurationChange?: return .routeConfigurationChange
        default: return .other
        }
    }

    // MARK: - Sanitizing maps (enums only)

    static func status(_ status: MusicKit.MusicPlayer.PlaybackStatus) -> DirectModeStatus {
        switch status {
        case .stopped: return .stopped
        case .playing: return .playing
        case .paused: return .paused
        case .interrupted: return .interrupted
        case .seekingForward: return .seekingForward
        case .seekingBackward: return .seekingBackward
        @unknown default: return .unknown
        }
    }

    static func authorization(_ status: MusicAuthorization.Status) -> DirectModeAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }

    /// Port type only; never `portName` (it can be a person's device name).
    static func route(_ route: AVAudioSessionRouteDescription) -> DirectModeRoute {
        guard let port = route.outputs.first?.portType else { return .none }
        switch port {
        case .builtInSpeaker: return .speaker
        case .builtInReceiver: return .receiver
        case .headphones: return .headphones
        case .bluetoothA2DP: return .bluetoothA2DP
        case .bluetoothLE: return .bluetoothLE
        case .bluetoothHFP: return .bluetoothHFP
        case .airPlay: return .airPlay
        case .carAudio: return .carAudio
        case .usbAudio: return .usb
        case .HDMI: return .hdmi
        default: return .other
        }
    }
}

enum DirectModeError: Error {
    case catalogLookupIncomplete
    case notAuthorized
}
#endif
