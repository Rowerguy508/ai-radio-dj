#if AERODJ_P0_DIAG
// TEMPORARY P0 Experiment A: MusicKit Direct Mode (remove with #121 / #133) -Atlas
// Compiled only when the internal TestFlight workflow sets AERODJ_P0_DIAG. Never in App Store builds.
//
// The ONE type that sets the queue or calls play / pause / skip in Direct Mode. No DJ prep,
// no watchdog, no auto-skip, no auto-resume, no AVAudioSession configuration or activation:
// ApplicationMusicPlayer owns its session. The poll below only reads state; it issues nothing.
import AVFoundation
import AeroDJCore
import MusicKit
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

    private var now: Double { ProcessInfo.processInfo.systemUptime - openedAt }

    func start() {
        guard pollTask == nil else { return }
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
    }

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
                var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: DirectModeSongs.ids)
                request.limit = DirectModeSongs.ids.count
                let response = try await request.response()
                let byID = Dictionary(response.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let ordered = DirectModeSongs.ids.compactMap { byID[$0] }
                lookupFound = ordered.count
                guard ordered.count == DirectModeSongs.ids.count else {
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

    func play() { run(.play) { try await self.player.play() } }
    func resume() { run(.resume) { try await self.player.play() } }
    func next() { run(.next) { try await self.player.skipToNextEntry() } }

    func pause() {
        guard machine.request(.pause, at: now) else { return }
        player.pause()
        machine.finished(.pause, error: nil, at: now)
    }

    private func run(_ command: DirectModeCommand, _ body: @escaping @MainActor () async throws -> Void) {
        guard machine.request(command, at: now) else { return }
        Task {
            do {
                try await body()
                machine.finished(command, error: nil, at: now)
            } catch {
                machine.finished(command, error: PlaybackErrorCode(error), at: now)
            }
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

    // MARK: - Sanitizing maps (enums only)

    static func status(_ status: MusicPlayer.PlaybackStatus) -> DirectModeStatus {
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
