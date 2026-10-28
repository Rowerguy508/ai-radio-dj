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
    /// Experiment B (-Atlas): the layers this launch runs with. Level 0 changes nothing.
    let layers = DirectModeLayerHost(level: DirectModeLayerSettings.levelAtLaunch, songCount: DirectModeSongs.ids.count)
    /// Experiment B "S" (-Fry): build 14's app-owned session path. Off changes nothing.
    /// Forced off at level 8 (-Atlas): there MusicKitService owns the session and the player.
    let session = DirectModeSessionLayerHost(enabled: DirectModeSessionLayerSettings.enabledAtLaunch
                                             && !DirectModeLayerSettings.levelAtLaunch.routesThroughMusicKitService)
    /// Experiment B level 8 (-Atlas): commands through MusicKitService.shared, its play path traced.
    let servicePath = DirectModeServicePathHost(level: DirectModeLayerSettings.levelAtLaunch)

    private let player = ApplicationMusicPlayer.shared
    private let openedAt = ProcessInfo.processInfo.systemUptime
    private var loadedIDs: [MusicItemID] = []
    private var loadedSongs: [Song] = []
    private var pollTask: Task<Void, Never>?
    private var lastSubscriptionRead: Double = -.infinity

    private var now: Double { ProcessInfo.processInfo.systemUptime - openedAt }

    func start() {
        guard pollTask == nil else { return }
        layers.start(clock: { [weak self] in self?.now ?? 0 }, issue: { [weak self] in self?.issue($0) })
        servicePath.start(openedAt: openedAt)
        session.start(clock: { [weak self] in self?.now ?? 0 }, pause: { [weak self] in self?.player.pause() })
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
        layers.stop()
        servicePath.stop()
        session.stop()
    }

    /// Before Load only; the queue is set once.
    func selectSongSet(_ set: DirectModeSongSet) { machine.selectSongSet(set, at: now) }

    /// The tester heard the song.
    func markHeard() { machine.markHeard(at: now) }

    // MARK: - Commands (the only callers of ApplicationMusicPlayer commands)

    func load() {
        guard machine.request(.load, at: now) else { return }
        layers.userCommand(.load, at: now)
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
                loadedSongs = ordered
                layers.loaded(durations: ordered.map(\.duration))
                // B2+ loads one song at a time, like the normal app.
                if servicePath.isOn {
                    // Level 8: the service's launch path now; it sets its own one-song queue on Play.
                    await servicePath.engage()
                } else {
                    player.queue = ApplicationMusicPlayer.Queue(for: layers.stack.usesOneSongQueue ? [ordered[0]] : ordered)
                }
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
        layers.userCommand(.pause, at: now)
        session.userPause(at: now)
        if servicePath.isOn { servicePath.pause() } else { player.pause() }
        machine.finished(.pause, error: nil, at: now)
    }

    private func run(_ command: DirectModeCommand) {
        guard machine.request(command, at: now) else { return }
        layers.userCommand(command, at: now)
        servicePath.tapped(at: now)
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
        if servicePath.isOn { return try await servicePath.perform(command, songs: loadedSongs) }
        switch command {
        case .play, .resume: try await startPlayer()
        case .next:
            if layers.stack.usesOneSongQueue {
                try await loadAndPlay(layers.stack.queueIndex)
            } else {
                try await player.skipToNextEntry()
            }
        case .load, .pause: break  // handled by load() and pause()
        }
    }

    // MARK: - Observation only

    private func observe() async {
        let t = now
        machine.observe(status: Self.status(player.state.playbackStatus),
                        position: player.playbackTime,
                        entryIndex: currentEntryIndex(), at: t)
        issue(layers.observe(status: machine.status, position: machine.position,
                             entryIndex: machine.entryIndex, at: t))
        if machine.status == .playing, session.observePlaying(at: t) { player.pause() }
        machine.observeAuthorization(Self.authorization(MusicAuthorization.currentStatus), at: t)
        machine.observeRoute(Self.route(AVAudioSession.sharedInstance().currentRoute), at: t)
        if t - lastSubscriptionRead >= 5 {
            lastSubscriptionRead = t
            let subscription = try? await MusicSubscription.current
            machine.observeCanPlayCatalog(subscription?.canPlayCatalogContent, at: now)
        }
    }

    // MARK: - Experiment B layer actions (-Atlas). Only B2 and B4 ever ask; level 0 never does.

    private func issue(_ actions: [DirectModeLayerAction]) {
        for action in actions {
            switch action {
            case .pause:
                player.pause()
            case .resume, .loadAndPlay:
                Task {
                    do { try await performLayer(action) } catch { layers.actionFailed(action, at: now) }
                }
            }
        }
    }

    private func performLayer(_ action: DirectModeLayerAction) async throws {
        switch action {
        case .pause: player.pause()
        case .resume: try await startPlayer()
        case .loadAndPlay(let index): try await loadAndPlay(index)
        }
    }

    /// B2: one queue change (the song at `index` alone), then play.
    private func loadAndPlay(_ index: Int) async throws {
        guard loadedSongs.indices.contains(index) else { return }
        player.queue = ApplicationMusicPlayer.Queue(for: [loadedSongs[index]])
        try await startPlayer()
    }

    /// Every play() goes through here. With S off this is exactly `player.play()`.
    private func startPlayer() async throws {
        try session.beforePlay(at: now)
        try await player.play()
        if session.afterPlay(at: now) { player.pause() }
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
