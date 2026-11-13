import Foundation

// CarPlay (#438). The car shows station names, the current song's title, artist, and
// artwork, and the station that song belongs to. Spoken lines, playback errors, the
// rest of the queue, and a created station's kind summary are not fields on this
// screen: a caller cannot put them on the car by passing the snapshot through.

/// One station row on the car. Detail is a fixed built-in line, or nil.
public struct CarPlayStationRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let detail: String?
    public let symbol: CarPlayRowSymbol
    public let showsPlayingIndicator: Bool
    public let pick: CarPlayStationPick

    public init(id: String, name: String, detail: String?, symbol: CarPlayRowSymbol,
                showsPlayingIndicator: Bool, pick: CarPlayStationPick) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.showsPlayingIndicator = showsPlayingIndicator
        self.pick = pick
    }

    public var visibleText: [String] {
        [name, detail].compactMap { $0 }
    }
}

/// SF Symbol for a row. Chosen from the row kind, never from a summary or a fetched image.
public enum CarPlayRowSymbol: String, Equatable, Sendable {
    case morningCalm = "sun.horizon"
    case lateNight = "moon.stars"
    case builtInStation = "music.note.list"
    case createdStation = "radio"
}

/// One labeled group on the car list.
public struct CarPlayStationSection: Equatable, Sendable {
    public let title: String
    public let rows: [CarPlayStationRow]
    /// Plain hint when the section has no stations. Not a station row.
    public let hint: String?

    public init(title: String, rows: [CarPlayStationRow], hint: String?) {
        self.title = title
        self.rows = rows
        self.hint = hint
    }
}

public enum CarPlayStationPick: Equatable, Sendable {
    /// Morning Calm or Late Night. #454: starts through the same path as the phone's built-in tap.
    case builtIn
    /// A station the listener created. The car opens it with `openCreatedStation(.userTap)`.
    case created(UUID)
}

/// What picking a row does.
public enum CarPlayPickEffect: Equatable, Sendable {
    /// `StationQueuePlayer.openCreatedStation(.userTap)` for this recipe.
    case openCreatedStation(UUID)
    /// #454: the phone's built-in row tap, `StationQueuePlayer.openBuiltInStation(.userTap)`: the same
    /// start path as a created station (the station's own configuration from `BuiltInStations`, #442). Never resumes the old queue instead, and never a search.
    case openBuiltInStation
}

/// The phone's created-station row tap.
public enum CarPlayStationStart {
    public static let trigger = StationOpenTrigger.userTap
}

/// A built-in station name, as the phone list already shows it.
public struct CarPlayBuiltInStation: Equatable, Sendable {
    public let id: String
    public let name: String
    /// Phone copy such as "Warm, unhurried host". Shown only when it is one of the two fixed lines.
    public let detail: String?

    public init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// Song title, artist, station name, and the track's artwork URL. Nothing else.
public struct CarPlayNowPlaying: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let stationName: String
    public let artworkURL: URL?

    public init(title: String, artist: String, stationName: String, artworkURL: URL?) {
        self.title = title
        self.artist = artist
        self.stationName = stationName
        self.artworkURL = artworkURL
    }

    public var visibleText: [String] { [title, artist, stationName] }

    /// The album line on the car: the station name, one line, nothing else.
    public var albumCredit: String {
        let line = stationName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? AppName.display : line
    }
}

/// Now-playing text plus the transport at the time it was taken. Transport is not
/// shown. It is part of equality so a playback confirm republishes the station name
/// after the player writes its own now-playing info. A spoken line is not part of it.
public struct CarPlayNowPlayingPublication: Equatable, Sendable {
    public let fields: CarPlayNowPlaying
    public let transport: TransportState

    public init(fields: CarPlayNowPlaying, transport: TransportState) {
        self.fields = fields
        self.transport = transport
    }
}

/// The whole car screen.
public struct CarPlayScreenModel: Equatable, Sendable {
    public let sections: [CarPlayStationSection]
    public let nowPlaying: CarPlayNowPlaying?
    public let publication: CarPlayNowPlayingPublication?
    public let accessNotice: String?

    public var rows: [CarPlayStationRow] { sections.flatMap(\.rows) }

    public var visibleText: [String] {
        var lines: [String] = []
        for section in sections {
            lines.append(section.title)
            lines.append(contentsOf: section.rows.flatMap(\.visibleText))
            if let hint = section.hint { lines.append(hint) }
        }
        if let nowPlaying { lines.append(contentsOf: nowPlaying.visibleText) }
        if let accessNotice { lines.append(accessNotice) }
        return lines
    }
}

/// What `updateList` compares so a now-playing change still refreshes the nav button
/// when the rows themselves are unchanged.
public struct CarPlayListIdentity: Equatable, Sendable {
    public let titles: [String]
    public let ids: [String]
    public let names: [String]
    public let details: [String?]
    public let symbols: [String]
    public let playing: [Bool]
    public let hints: [String?]
    public let notice: String?
    /// True when the Now Playing navigation button should be on the list.
    public let hasNowPlaying: Bool

    public init(_ model: CarPlayScreenModel) {
        titles = model.sections.map(\.title)
        ids = model.rows.map(\.id)
        names = model.rows.map(\.name)
        details = model.rows.map(\.detail)
        symbols = model.rows.map(\.symbol.rawValue)
        playing = model.rows.map(\.showsPlayingIndicator)
        hints = model.sections.map(\.hint)
        notice = model.accessNotice
        hasNowPlaying = model.nowPlaying != nil
    }
}

public enum CarPlayScreen {
    public static let yourStationsTitle = "Your stations"
    public static let builtInTitle = "Built-in"
    public static let emptyCreatedHint = "Save a station in \(AppName.display) to play it here."
    public static let morningCalmDetail = "Warm, unhurried host"
    public static let lateNightDetail = "Smooth vinyl-bar vibes"

    /// Your stations, then Built-in. A blank name is left off. Created summaries are not read.
    public static func project(builtIn: [CarPlayBuiltInStation],
                               created: [CreatedStationEntry],
                               snapshot: PlaybackSnapshot,
                               opened: StationRef?,
                               access: PlaybackAccess) -> CarPlayScreenModel {
        let nowPlaying = nowPlayingItem(snapshot: snapshot, opened: opened)
        let publication = nowPlaying.map { CarPlayNowPlayingPublication(fields: $0, transport: snapshot.transport) }
        let onAir = onAirStationID(snapshot: snapshot, opened: opened)
        let sections = [
            createdSection(created, onAir: onAir),
            builtInSection(builtIn, onAir: onAir),
        ].compactMap { $0 }
        return CarPlayScreenModel(sections: sections, nowPlaying: nowPlaying, publication: publication,
                                  accessNotice: accessNotice(for: access))
    }

    /// Created rows use `openCreatedStation(.userTap)`; built-in rows `openBuiltInStation(.userTap)`
    /// (#454: both start the station on the phone's start path, whatever the transport).
    public static func effect(for pick: CarPlayStationPick, transport: TransportState) -> CarPlayPickEffect {
        _ = transport
        switch pick {
        case .created(let id):
            return .openCreatedStation(id)
        case .builtIn:
            return .openBuiltInStation
        }
    }

    /// Fixed phone copy for a block that is not "authorized". Nil when the list can just show stations.
    public static func accessNotice(for access: PlaybackAccess) -> String? {
        switch access {
        case .checking, .authorized:
            nil
        case .needsAuthorization:
            NowPlayingContent.needsAuthorization.title
        case .denied:
            NowPlayingContent.accessDenied.title
        case .subscriptionRequired:
            NowPlayingContent.subscriptionRequired.title
        }
    }

    private static func createdSection(_ created: [CreatedStationEntry], onAir: String?) -> CarPlayStationSection? {
        let rows = created.compactMap { station -> CarPlayStationRow? in
            guard let name = displayName(station.name) else { return nil }
            let id = station.id.uuidString
            return CarPlayStationRow(id: id, name: name, detail: nil, symbol: .createdStation,
                                    showsPlayingIndicator: id == onAir, pick: .created(station.id))
        }
        if rows.isEmpty {
            return CarPlayStationSection(title: yourStationsTitle, rows: [], hint: emptyCreatedHint)
        }
        return CarPlayStationSection(title: yourStationsTitle, rows: rows, hint: nil)
    }

    private static func builtInSection(_ builtIn: [CarPlayBuiltInStation], onAir: String?) -> CarPlayStationSection? {
        let rows = builtIn.compactMap { station -> CarPlayStationRow? in
            guard let name = displayName(station.name) else { return nil }
            return CarPlayStationRow(id: station.id, name: name, detail: allowedDetail(station.detail),
                                    symbol: symbol(forBuiltInNamed: name),
                                    showsPlayingIndicator: station.id == onAir, pick: .builtIn)
        }
        guard !rows.isEmpty else { return nil }
        return CarPlayStationSection(title: builtInTitle, rows: rows, hint: nil)
    }

    private static func symbol(forBuiltInNamed name: String) -> CarPlayRowSymbol {
        switch name {
        case "Morning Calm": .morningCalm
        case "Late Night": .lateNight
        default: .builtInStation
        }
    }

    private static func allowedDetail(_ detail: String?) -> String? {
        guard let detail, detail == morningCalmDetail || detail == lateNightDetail else { return nil }
        return detail
    }

    /// Nil unless a song is on the session. The id is the station that owns that song.
    private static func onAirStationID(snapshot: PlaybackSnapshot, opened: StationRef?) -> String? {
        switch snapshot.transport {
        case .stopped:
            return nil
        case .playing, .paused, .preparing:
            guard snapshot.nowPlaying != nil || snapshot.transport == .preparing else { return nil }
            return nowPlayingStation(snapshot: snapshot, opened: opened).id
        }
    }

    private static func nowPlayingStation(snapshot: PlaybackSnapshot, opened: StationRef?) -> StationRef {
        let fallback = opened ?? StationRef(id: "app", name: AppName.display)
        return StationHeading(opened: fallback, playing: snapshot.station).nowPlaying
    }

    private static func displayName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : name
    }

    /// Title, artist, and artwork come from the current track only.
    /// The station name is `StationHeading.nowPlaying` (the session's station, or the
    /// one the listener just opened, or the app name when neither is known).
    private static func nowPlayingItem(snapshot: PlaybackSnapshot, opened: StationRef?) -> CarPlayNowPlaying? {
        guard let track = snapshot.nowPlaying else { return nil }
        let station = nowPlayingStation(snapshot: snapshot, opened: opened)
        return CarPlayNowPlaying(title: track.title, artist: track.artistName,
                                 stationName: station.name, artworkURL: track.artworkURL)
    }
}

/// Play, pause, and next stay on `MPRemoteCommandCenter` (the lock-screen path).
/// Previous has no app path and stays off. This type does not perform a skip.
public enum CarPlayTransport {
    public static let previousTrackEnabled = false

    public static func nextTrackEnabled(queueIndex: Int, queueCount: Int) -> Bool {
        RemoteNextCommand.isEnabled(queueIndex: queueIndex, queueCount: queueCount)
    }
}

/// Writes the car's now-playing text onto the dictionary the system template already shows.
///
/// The string values are MediaPlayer's item keys (`title`, `artist`, `albumTitle`,
/// `lyrics`, `comments`). The station name uses the album line, which is where CarPlay
/// shows a second credit under the artist. Elapsed time, duration, and rate are left
/// as the player published them. Lyrics and comments are removed.
public enum CarPlayNowPlayingMerge {
    public static let titleKey = "title"
    public static let artistKey = "artist"
    public static let stationNameKey = "albumTitle"
    public static let lyricsKey = "lyrics"
    public static let commentsKey = "comments"
    public static let removedKeys = [lyricsKey, commentsKey]

    public static func apply(fields: CarPlayNowPlaying, to info: [String: Any]) -> [String: Any] {
        var next = info
        next[titleKey] = fields.title
        next[artistKey] = fields.artist
        next[stationNameKey] = fields.albumCredit
        for key in removedKeys { next.removeValue(forKey: key) }
        return next
    }
}

/// What a render does with the now-playing publication (#449).
public enum CarPlayPublicationStep: Equatable, Sendable {
    /// Nothing changed. No write.
    case keep
    /// A new or changed publication: write it through the artwork gate.
    case apply(CarPlayNowPlaying)
    /// The song is gone: void any artwork fetch for it (`CarPlayArtworkGate.reset()`). No write.
    case withdraw

    public static func next(from last: CarPlayNowPlayingPublication?,
                            to current: CarPlayNowPlayingPublication?) -> Self {
        guard let current else { return last == nil ? .keep : .withdraw }
        return current == last ? .keep : .apply(current.fields)
    }
}

/// What image the shared now-playing dictionary actually holds when a publish starts (#449).
///
/// The bridge reads it from the dictionary itself, not from what the gate last decided, so a
/// reconnect cannot leave the previous song's image under the next song's title.
public enum CarPlayArtworkObservation: Equatable, Sendable {
    /// No image in the dictionary.
    case none
    /// The image the bridge itself last wrote, for this URL.
    case written(URL)
    /// An image the bridge cannot vouch for: another writer's, or one from before a reset.
    case unknown

    /// `current` is the image in the dictionary now. `written` is the image object the bridge
    /// last set (the same instance, not an equal one) and `writtenURL` the URL it was set for.
    public static func observe(current: AnyObject?, written: AnyObject?, writtenURL: URL?) -> Self {
        guard let current else { return .none }
        guard let written, let writtenURL, current === written else { return .unknown }
        return .written(writtenURL)
    }
}

/// Decides what a now-playing publish does to text and artwork.
///
/// The publication generation is the track. The URL is the artwork. A fetch may set
/// artwork only when its token is still the open one and the URL is still the latest
/// publication's URL. It never carries title, artist, or station name, so a late fetch
/// cannot write an older song back over the one on screen.
///
/// #449: the generation only ever grows, across `reset()` too, so a fetch begun before a
/// disconnect can never match a token handed out after it. The first publish after `init` or
/// `reset()` reconciles with the dictionary's real image (`CarPlayArtworkObservation`): an image
/// the bridge cannot vouch for is cleared at once, a known match for the same URL is kept
/// without a reload.
public struct CarPlayArtworkGate: Equatable, Sendable {
    public struct Token: Equatable, Sendable, Hashable {
        public var id: UInt64
        public var url: URL

        public init(id: UInt64, url: URL) {
            self.id = id
            self.url = url
        }
    }

    public enum Command: Equatable, Sendable {
        /// Replace title, artist, and station name. Does not touch artwork.
        case writeText(CarPlayNowPlaying)
        /// Remove the current image now. No text.
        case clearArtwork
        /// Load this URL for this publication. A newer publish invalidates the token.
        case startFetch(Token)
    }

    public enum Arrival: Equatable, Sendable {
        /// The publication moved on. Do not write text or artwork.
        case ignore
        /// Set the image for this URL only. Do not write title, artist, or station name.
        case setArtwork(URL)
    }

    private var generation: UInt64 = 0
    private var latestURL: URL?
    private var openFetch: Token?
    private var showing: URL?
    /// True until the first publish after `init` or `reset()` has read the real dictionary.
    private var needsReconcile = true

    public init() {}

    /// The car disconnected, or there is no song to show (#449). Any fetch already started is
    /// void, and the next publish reconciles with the dictionary instead of trusting this gate.
    /// Writes nothing: the dictionary's other fields stay as the player left them.
    public mutating func reset() {
        generation += 1
        latestURL = nil
        openFetch = nil
        showing = nil
        needsReconcile = true
    }

    /// `observed` is the dictionary's image right now. The first publish after `init` or
    /// `reset()` uses it: `.unknown` is cleared at once, `.none` and `.written` replace the
    /// gate's own belief. Later publishes follow the gate (nil: the same).
    public mutating func publish(_ fields: CarPlayNowPlaying, observed: CarPlayArtworkObservation?) -> [Command] {
        var mustClear = false
        if needsReconcile, let observed {
            needsReconcile = false
            switch observed {
            case .none:
                showing = nil
            case .written(let url):
                showing = url
            case .unknown:
                showing = nil
                mustClear = true
            }
        }
        return publish(fields, mustClear: mustClear)
    }

    public mutating func publish(_ fields: CarPlayNowPlaying) -> [Command] {
        publish(fields, mustClear: false)
    }

    private mutating func publish(_ fields: CarPlayNowPlaying, mustClear: Bool) -> [Command] {
        generation += 1
        var commands: [Command] = [.writeText(fields)]
        guard let url = fields.artworkURL else {
            if showing != nil || openFetch != nil || mustClear { commands.append(.clearArtwork) }
            showing = nil
            openFetch = nil
            latestURL = nil
            return commands
        }
        latestURL = url
        if showing == url, openFetch == nil { return commands }
        if openFetch?.url == url { return commands }
        if showing != nil || openFetch != nil || mustClear { commands.append(.clearArtwork) }
        showing = nil
        let token = Token(id: generation, url: url)
        openFetch = token
        commands.append(.startFetch(token))
        return commands
    }

    /// A fetch finished. The caller supplies the token it started with, not a copy of the
    /// song that was current then.
    public mutating func fetchArrived(_ token: Token) -> Arrival {
        guard openFetch == token, latestURL == token.url else { return .ignore }
        openFetch = nil
        showing = token.url
        return .setArtwork(token.url)
    }

    /// The load failed or produced no image. A later publish of the same URL may try again.
    public mutating func fetchFailed(_ token: Token) {
        guard openFetch == token else { return }
        openFetch = nil
    }
}
