import AeroDJCore
import Combine
import Foundation
import Observation
import OSLog
import UIKit
#if canImport(NowPlaying)
import NowPlaying
#endif

/// #539 follow-up (-Fry): which Now Playing API this launch uses. iOS 27 and later use the OnAirly
/// NowPlaying session while the cached `onAirlyNowPlayingSession` flag (`GET /api/flags`) is on; earlier
/// systems keep build 56's path: MusicKit's card, `MPRemoteCommandCenter` targets, the CarPlay bridge.
/// Apple: don't mix the NowPlaying framework with `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`.
enum OnAirlyNowPlaying {
    /// The system has the NowPlaying framework. Decided once.
    static let osSupportsSession: Bool = {
        #if canImport(NowPlaying)
        guard #available(iOS 27.0, *) else { return false }
        return OnAirlyNowPlayingPolicy.usesSession(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                                   enabled: true)
        #else
        return false
        #endif
    }()

    /// This launch's path, decided once: iOS 27 and the flag value cached by an earlier launch
    /// (`OnAirlySessionFlag.launchValue`, no cache: on). `MusicKitService.installRemoteCommands()`,
    /// the CarPlay bridge and the session all read this same value, so a launch never has both
    /// APIs or neither. This launch's fetch only updates the cache for the next launch.
    static let usesSession: Bool = osSupportsSession && OnAirlyNowPlayingPolicy.sessionEnabled
}

/// #539 follow-up (owner: "I just want the live player to replace the Apple Music one").
///
/// Publishes one OnAirly `MediaSession`: the song title, "Artist · DJ on air / DJ break after this
/// song / Station" as the subtitle, the song's artwork, and our own commands, which run the same
/// gated paths as the in-app controls (`resume()`, `pause()`, `skip()`, `seek(to:trackID:)`).
/// From the foreground, once audio is playing, it asks to be the system's primary session.
///
/// NOT device evidence: Apple says the request "doesn't guarantee the system displays your
/// session", and MusicKit's player is a separate, out-of-process Now Playing client. Build 57
/// decides whether this card replaces MusicKit's on the lock screen. The `nowplaying` log
/// category records only command names and primary flags (no titles, IDs or artwork).
///
/// Never on the playback path: observers only hop to the main actor and update a model.
@MainActor
final class OnAirlyNowPlayingSession {
    static let shared = OnAirlyNowPlayingSession()

    enum Command {
        case play, pause, toggle, next
        case seek(TimeInterval)

        var name: String {
            switch self {
            case .play: "play"
            case .pause: "pause"
            case .toggle: "toggle"
            case .next: "next"
            case .seek: "seek"
            }
        }
    }

    private var started = false
    private var watchers = Set<AnyCancellable>()
    private var djTask: Task<Void, Never>?
    private var snapshot = PlaybackSnapshot()
    private var dj: DJStudioState = .idle
    private weak var playback: MusicKitService?
    /// `OnAirlyMediaPublisher` on iOS 27 (a stored property cannot be marked iOS 27 only).
    private var publisher: AnyObject?
    private var primaryRequestInFlight = false
    private let log = Logger(subsystem: "com.aerodj.app", category: "nowplaying")

    private init() {}

    func start(_ dependencies: AppDependencies) {
        guard !started, OnAirlyNowPlaying.osSupportsSession else { return }
        started = true
        // Pin this launch's path BEFORE the fetch can write the cache (both lets are lazy).
        let usesSession = OnAirlyNowPlaying.usesSession
        // Once per launch, off the main actor: a bare GET (no token, cookie or identifier). It only
        // updates the cache the NEXT launch starts with; this launch's path is already fixed.
        Task.detached(priority: .utility) {
            await OnAirlySessionFlag.refresh(transport: DJAirPlayRouteFlag.makeTransport(),
                                             baseURL: DJAirPlayRouteFlag.proxyBaseURL,
                                             cache: UserDefaultsOnAirlySessionFlagCache.shared)
        }
        guard usesSession else {
            log.notice("session off by cached flag")
            return
        }
        playback = dependencies.playback
        snapshot = dependencies.playback.snapshot
        dj = dependencies.dj.studioState
        dependencies.playback.$snapshot
            .sink { snapshot in
                Task { @MainActor in OnAirlyNowPlayingSession.shared.snapshotChanged(snapshot) }
            }
            .store(in: &watchers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { _ in
                Task { @MainActor in OnAirlyNowPlayingSession.shared.publish() }
            }
            .store(in: &watchers)
        let store = dependencies.dj
        djTask = Task { @MainActor in
            for await state in store.updates() {
                OnAirlyNowPlayingSession.shared.djChanged(DJStudioState(state))
            }
        }
        publish()
    }

    private func snapshotChanged(_ snapshot: PlaybackSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        publish()
    }

    private func djChanged(_ state: DJStudioState) {
        guard state != dj else { return }
        dj = state
        publish()
    }

    /// A lock-screen, Control Center or CarPlay command. Same gates as the in-app controls.
    func perform(_ command: Command) async {
        guard let playback else { return }
        log.notice("command \(command.name, privacy: .public)")
        switch command {
        case .play:
            // Explicit user intent: clears system holds the same way in-app Play does.
            _ = try? await playback.resume()
        case .pause:
            playback.pause()
        case .toggle:
            let transport = playback.snapshot.transport
            if playback.isPlaying || transport == .playing || transport == .preparing {
                playback.pause()
            } else {
                _ = try? await playback.resume()
            }
        case .next:
            // Same rule as the MediaPlayer path's `nextTrackCommand`: `RemoteNextCommand.decide`.
            let position = playback.remoteNextPosition
            guard RemoteNextCommand.decide(queueIndex: position.queueIndex,
                                           queueCount: position.queueCount) == .skip else { return }
            _ = try? await playback.skip()
        case .seek(let position):
            // Blocked (no player change) during a DJ break or a load, like the scrubber.
            _ = playback.seek(to: position, trackID: playback.snapshot.nowPlaying?.id)
        }
        publish()
    }

    private func publish() {
        #if canImport(NowPlaying)
        guard #available(iOS 27.0, *), let playback else { return }
        let position = playback.remoteNextPosition
        guard let card = OnAirlyNowPlayingCard.make(snapshot: snapshot, dj: dj, duration: playback.currentDuration,
                                                    queueIndex: position.queueIndex,
                                                    queueCount: position.queueCount) else {
            if publisher != nil { log.notice("session removed") }
            publisher = nil
            return
        }
        let pub: OnAirlyMediaPublisher
        if let existing = publisher as? OnAirlyMediaPublisher {
            pub = existing
        } else {
            pub = OnAirlyMediaPublisher()
            publisher = pub
            log.notice("session created")
        }
        pub.model.update(card: card, elapsed: card.publishedElapsed(playback.playbackTime))
        let wantsSystem = OnAirlyNowPlayingPolicy.shouldRequestSystemPrimary(
            card: card, appInForeground: UIApplication.shared.applicationState == .active,
            isSystemPrimary: pub.session.isSystemPrimary)
        guard !primaryRequestInFlight, wantsSystem || !pub.session.isApplicationPrimary else { return }
        primaryRequestInFlight = true
        Task { @MainActor in
            await self.requestPrimary(pub, system: wantsSystem)
            self.primaryRequestInFlight = false
        }
        #endif
    }

    #if canImport(NowPlaying)
    @available(iOS 27.0, *)
    private func requestPrimary(_ pub: OnAirlyMediaPublisher, system: Bool) async {
        do {
            if !pub.session.isApplicationPrimary {
                try await pub.session.requestToBecomeApplicationPrimary()
            }
            // Apple: a background request has no effect, so this is asked only from the foreground.
            if system, publisher === pub, !pub.session.isSystemPrimary {
                try await pub.session.requestToBecomeSystemPrimary()
            }
        } catch {
            log.notice("primary request failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        log.notice("primary app=\(pub.session.isApplicationPrimary, privacy: .public) system=\(pub.session.isSystemPrimary, privacy: .public)")
    }
    #endif
}

#if canImport(NowPlaying)
/// The model and its session, kept together so the session lives exactly as long as the card.
@available(iOS 27.0, *)
@MainActor
final class OnAirlyMediaPublisher {
    let model = OnAirlyMediaModel()
    let session: MediaSession<OnAirlyMediaModel>

    init() {
        session = MediaSession(model)
    }
}

/// What the system reads. Everything comes from `OnAirlyNowPlayingCard` (Core, tested on Linux).
@available(iOS 27.0, *)
@MainActor
@Observable
final class OnAirlyMediaModel: MediaSessionRepresentable {
    let id = "com.aerodj.app.onairly"
    private(set) var card: OnAirlyNowPlayingCard?
    private(set) var elapsed: TimeInterval?
    private(set) var elapsedStamp: Date?

    func update(card: OnAirlyNowPlayingCard, elapsed: TimeInterval?) {
        if self.card != card { self.card = card }
        self.elapsed = elapsed
        elapsedStamp = elapsed == nil ? nil : Date()
    }

    var content: (any MediaContentRepresentable)? {
        guard let card else { return nil }
        let artwork = card.artworkURL.map { url in
            Artwork(id: url.absoluteString) { _ in
                let (data, _) = try await URLSession.shared.data(from: url)
                return try ArtworkRepresentation(data: data)
            }
        }
        return GenericContent(id: card.contentID, title: card.title, subtitle: card.subtitle, type: .audio,
                              duration: card.duration.map { MediaDuration.finite($0) } ?? .continuous,
                              artwork: artwork)
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard let card else { return nil }
        let state: MediaPlaybackSnapshot.PlaybackState
        switch card.transport {
        case .playing: state = .playing()
        case .paused: state = .paused
        case .buffering: state = .buffering
        }
        return MediaPlaybackSnapshot(state: state, elapsedTime: elapsed, timestamp: elapsedStamp)
    }

    var commands: [MediaCommand] {
        guard let card else { return [] }
        // No Previous: the app has no previous-song path (same as `CarPlayTransport`).
        return [
            .play { await OnAirlyNowPlayingSession.shared.perform(.play) },
            .pause { await OnAirlyNowPlayingSession.shared.perform(.pause) },
            .togglePlayPause { await OnAirlyNowPlayingSession.shared.perform(.toggle) },
            .next { await OnAirlyNowPlayingSession.shared.perform(.next) }.enabled(card.nextEnabled),
            .seekToPosition { position in
                await OnAirlyNowPlayingSession.shared.perform(.seek(position))
            }.enabled(card.canSeek),
        ]
    }
}
#endif
