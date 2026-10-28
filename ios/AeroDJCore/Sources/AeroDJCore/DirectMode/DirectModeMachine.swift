// Compiled only in Debug (so `swift test` and Debug CI run its tests) and in AERODJ_P0_DIAG
// builds. A plain Release, which is what the App Store gets, carries none of it. -Atlas
#if DEBUG || AERODJ_P0_DIAG
import Foundation

// P0 Playback Recovery, Experiment A (-Atlas). Pure state for MusicKit Direct Mode: one
// controller owns ApplicationMusicPlayer; this machine decides which user command may run,
// latches what the device has proven, and keeps a sanitized transition log.
// Sanitized means: enums, booleans, numbers, error type name + NSError domain + code.
// No titles, catalog IDs, storefront, route names or localizedDescription ever enter it.
// The app-side UI and controller are compiled only under AERODJ_P0_DIAG (remove: #121, #133).

/// `MusicPlayer.PlaybackStatus`, as a Sendable value. `.unknown` covers a future case.
public enum DirectModeStatus: String, Equatable, Sendable, CaseIterable {
    case stopped, playing, paused, interrupted, seekingForward, seekingBackward, unknown
}

/// The only commands Direct Mode issues. `load` sets the queue (both songs, once).
public enum DirectModeCommand: String, Equatable, Sendable, CaseIterable {
    case load, play, pause, resume, next
}

/// Output kinds from `AVAudioSession.currentRoute` port types. Never a port name.
public enum DirectModeRoute: String, Equatable, Sendable {
    case speaker, receiver, headphones, bluetoothA2DP, bluetoothLE, bluetoothHFP, airPlay,
         carAudio, usb, hdmi, other, none
}

public enum DirectModeAuthorization: String, Equatable, Sendable {
    case notDetermined, denied, restricted, authorized, unknown
}

public struct DirectModeLogEntry: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        case requested(DirectModeCommand)
        case refused(DirectModeCommand, reason: String)
        case finished(DirectModeCommand)
        case failed(DirectModeCommand, PlaybackErrorCode)
        case status(DirectModeStatus)
        case entry(Int?)
        case firstPlaying
        case positionAdvanced
        case unexpectedQueue
        case authorization(DirectModeAuthorization)
        case canPlayCatalog(Bool?)
        case route(DirectModeRoute)
        /// The tester tapped "I hear it".
        case heard
        case songSet(DirectModeSongSet)
    }

    /// Seconds since Direct Mode opened.
    public let t: Double
    public let kind: Kind
    public let status: DirectModeStatus
    public let position: Double

    public var description: String {
        let head = "+" + String(format: "%.2f", t) + "s pos=" + String(format: "%.1f", position) + " \(status.rawValue) "
        switch kind {
        case .requested(let c): return head + "cmd.\(c.rawValue).requested"
        case let .refused(c, reason): return head + "cmd.\(c.rawValue).refused \(reason)"
        case .finished(let c): return head + "cmd.\(c.rawValue).ok"
        case let .failed(c, code): return head + "cmd.\(c.rawValue).threw \(code)"
        case .status(let s): return head + "status=\(s.rawValue)"
        case .entry(let i): return head + "entry=\(i.map(String.init) ?? "none")"
        case .firstPlaying: return head + "PLAYING.reached"
        case .positionAdvanced: return head + "position.advanced"
        case .unexpectedQueue: return head + "queue.UNEXPECTED"
        case .authorization(let a): return head + "auth=\(a.rawValue)"
        case .canPlayCatalog(let b): return head + "canPlayCatalogContent=\(b.map(String.init) ?? "nil")"
        case .route(let r): return head + "route=\(r.rawValue)"
        case .heard: return head + "HEARD"
        case .songSet(let set): return head + "songSet=\(set.rawValue)"
        }
    }
}

/// Which pair of songs the queue is loaded with (-Fry). Chosen before Load; the queue loads once.
public enum DirectModeSongSet: String, Equatable, Sendable, CaseIterable {
    /// Song A then song B (build 13's queue).
    case standard
    /// A track that is loud from 0:00 first, then song A.
    case loudFirst
}

public struct DirectModeMachine: Equatable, Sendable {
    /// Position past this many seconds while `.playing` counts as "moved past 0:00".
    public static let advanceThreshold: Double = 1.0
    public static let logCapacity = 300

    public private(set) var inFlight: DirectModeCommand?
    public private(set) var queueLoaded = false
    public private(set) var status: DirectModeStatus = .stopped
    public private(set) var position: Double = 0
    /// Index into the hard-coded song list; nil when the player's entry is not one of ours.
    public private(set) var entryIndex: Int?
    public private(set) var everPlaying = false
    public private(set) var positionEverAdvanced = false
    public private(set) var unexpectedQueueSeen = false
    public private(set) var authorization: DirectModeAuthorization = .unknown
    public private(set) var canPlayCatalogContent: Bool?
    public private(set) var route: DirectModeRoute = .none
    public private(set) var lastError: PlaybackErrorCode?
    public private(set) var log: [DirectModeLogEntry] = []

    /// When the last play/resume was requested (-Fry), for the "I hear it" mark.
    public private(set) var playRequestedAt: Double?
    /// Seconds after the play/resume request when the tester first tapped "I hear it".
    public private(set) var heardAfterPlay: Double?
    public private(set) var songSet: DirectModeSongSet = .standard

    public let songCount: Int

    public init(songCount: Int) {
        self.songCount = songCount
    }

    /// Why `command` may not run now, or nil when it may.
    public func refusal(_ command: DirectModeCommand) -> String? {
        if let inFlight { return "busy.\(inFlight.rawValue)" }
        switch command {
        case .load:
            return queueLoaded ? "alreadyLoaded" : nil
        case .play:
            guard queueLoaded else { return "notLoaded" }
            return status == .playing ? "alreadyPlaying" : nil
        case .pause:
            return status == .playing ? nil : "notPlaying"
        case .resume:
            guard queueLoaded else { return "notLoaded" }
            return status == .paused ? nil : "notPaused"
        case .next:
            guard queueLoaded else { return "notLoaded" }
            guard let entryIndex else { return "entryUnknown" }
            return entryIndex + 1 < songCount ? nil : "lastEntry"
        }
    }

    /// The user asked for `command`. True when the controller should issue it now.
    @discardableResult
    public mutating func request(_ command: DirectModeCommand, at t: Double) -> Bool {
        if let reason = refusal(command) {
            append(.refused(command, reason: reason), at: t)
            return false
        }
        inFlight = command
        append(.requested(command), at: t)
        if command == .play || command == .resume {
            playRequestedAt = t
            heardAfterPlay = nil
        }
        return true
    }

    /// The command the controller issued returned. `error` is nil on success.
    public mutating func finished(_ command: DirectModeCommand, error: PlaybackErrorCode?, at t: Double) {
        guard inFlight == command else { return }
        inFlight = nil
        if let error {
            lastError = error
            append(.failed(command, error), at: t)
        } else {
            if command == .load { queueLoaded = true; entryIndex = 0 }
            append(.finished(command), at: t)
        }
    }

    /// A read of the player (observation only; it never issues a command).
    /// `entryIndex` is nil when the current entry is not one of the hard-coded songs.
    public mutating func observe(status newStatus: DirectModeStatus, position newPosition: Double,
                                 entryIndex newEntry: Int?, at t: Double) {
        position = newPosition
        if newStatus != status {
            status = newStatus
            append(.status(newStatus), at: t)
        }
        if newStatus == .playing, !everPlaying {
            everPlaying = true
            append(.firstPlaying, at: t)
        }
        if newStatus == .playing, newPosition >= Self.advanceThreshold, !positionEverAdvanced {
            positionEverAdvanced = true
            append(.positionAdvanced, at: t)
        }
        if queueLoaded, newEntry != entryIndex {
            entryIndex = newEntry
            append(.entry(newEntry), at: t)
            if newEntry == nil {
                unexpectedQueueSeen = true
                append(.unexpectedQueue, at: t)
            }
        }
    }

    public mutating func observeAuthorization(_ value: DirectModeAuthorization, at t: Double) {
        guard value != authorization else { return }
        authorization = value
        append(.authorization(value), at: t)
    }

    public mutating func observeCanPlayCatalog(_ value: Bool?, at t: Double) {
        guard value != canPlayCatalogContent else { return }
        canPlayCatalogContent = value
        append(.canPlayCatalog(value), at: t)
    }

    public mutating func observeRoute(_ value: DirectModeRoute, at t: Double) {
        guard value != route else { return }
        route = value
        append(.route(value), at: t)
    }

    /// Choose the queue's songs. Only before Load: the queue is set exactly once.
    @discardableResult
    public mutating func selectSongSet(_ set: DirectModeSongSet, at t: Double) -> Bool {
        guard !queueLoaded, inFlight != .load else { return false }
        guard set != songSet else { return true }
        songSet = set
        append(.songSet(set), at: t)
        return true
    }

    /// The tester heard the song. Only the first tap after each play/resume is latched.
    public mutating func markHeard(at t: Double) {
        if heardAfterPlay == nil, let start = playRequestedAt { heardAfterPlay = t - start }
        append(.heard, at: t)
    }

    private mutating func append(_ kind: DirectModeLogEntry.Kind, at t: Double) {
        log.append(DirectModeLogEntry(t: t, kind: kind, status: status, position: position))
        if log.count > Self.logCapacity { log.removeFirst(log.count - Self.logCapacity) }
    }
}

/// What one read of `ApplicationMusicPlayer.queue.currentEntry` showed, before it is turned
/// into an entry index. Keeps the "is this an unexpected queue?" decision in tested Core code.
public enum DirectModeEntrySighting: Equatable, Sendable {
    /// No current entry at all (before the first play).
    case noEntry
    /// An entry whose `item` is still nil (transient while MusicKit resolves it).
    case itemPending
    /// A song; `loadedIndex` is its position among the loaded IDs, nil when it is none of them.
    case song(loadedIndex: Int?)
    /// A non-nil item that is not a song.
    case notSong

    /// The entry index to report. A missing or still-resolving entry keeps `current`, so only
    /// a real foreign item can latch `unexpectedQueueSeen` (Orion, #134 review B2).
    public func entryIndex(keeping current: Int?) -> Int? {
        switch self {
        case .noEntry, .itemPending: return current
        case let .song(loadedIndex): return loadedIndex
        case .notSong: return nil
        }
    }
}
#endif
