import Foundation

// #465 item 7: StandBy, the Now Playing widget and the on-air Live Activity.
//
// Everything that leaves the app process for those surfaces (the App Group file the widget
// reads, and the ActivityKit content state) is one `NowPlayingDisplay` value and nothing else.
// Echo's and Sentinel's rules, enforced here and in NowPlayingDisplayTests:
// - Display fields only: station, track, artist, art, playback state, on-air label, ready label.
// - No script or briefing text, ever (`DJActivity.speaking(line:)` is never read). The ready
//   line is fixed copy, never `dj.detail` (which mentions briefing and duration).
// - No tokens, user ID, consent state or tester_voice data (there is no field for them, and a
//   test pins the exact encoded key set).
// - "On Air" comes only from `DJStudioState.onAirLabel` (confirmed `.speaking`); no new flag.
// - Ready ("DJ break after this song") is set only for `DJStudioState.ready`. It never uses
//   the On Air label, and `widgetCopy` always drops it (a widget timeline can't take it back
//   if the break becomes a quiet skip). Failed and idle carry no line.
// - An older payload without `readyLabel` decodes as not-ready.
// - Station, track, artist and art are privacy-sensitive: redacted while locked by default.

/// The only payload the widget and the Live Activity ever see.
public struct NowPlayingDisplay: Codable, Equatable, Hashable, Sendable {
    /// Playback state as the surfaces show it.
    public enum State: String, Codable, Hashable, Sendable {
        case stopped
        case starting
        case playing
        case paused
    }

    /// Generated cover (gradient and monogram) from `StationArtStyle`. No URL and no image data:
    /// the widget draws it, so nothing is fetched from the extension.
    public struct Art: Codable, Equatable, Hashable, Sendable {
        public let hues: [Double]
        public let saturation: Double
        public let brightness: Double
        public let monogram: String
        public let angle: Int

        public init(hues: [Double], saturation: Double, brightness: Double, monogram: String, angle: Int) {
            self.hues = hues
            self.saturation = saturation
            self.brightness = brightness
            self.monogram = monogram
            self.angle = angle
        }

        public init(_ style: StationArtStyle) {
            self.init(hues: style.hues, saturation: style.saturation, brightness: style.brightness,
                      monogram: style.monogram, angle: style.angle)
        }
    }

    public let station: String?
    public let track: String?
    public let artist: String?
    public let art: Art?
    public let state: State
    /// `DJStudioState.onAirLabel`: "On Air" only while the player confirms the DJ is speaking.
    public let onAirLabel: String?
    /// "DJ break after this song" only while `DJStudioState` is `.ready`. Nil for speaking
    /// (On Air is enough), failed (quiet skip), idle, preparing, and a stopped player.
    /// Optional so an older payload without this key decodes as not-ready.
    public let readyLabel: String?

    /// Fixed Live Activity copy for a prepared break. Not taken from `DJStudioState.detail`.
    public static let readyLineCopy = "DJ break after this song"

    public init(station: String?, track: String?, artist: String?, art: Art?, state: State,
                onAirLabel: String?, readyLabel: String? = nil) {
        self.station = station
        self.track = track
        self.artist = artist
        self.art = art
        self.state = state
        self.onAirLabel = onAirLabel
        self.readyLabel = readyLabel
    }

    /// The ready line for a studio state. Only `.ready` returns copy; failed stays a quiet skip.
    public static func readyLabel(for dj: DJStudioState) -> String? {
        if case .ready = dj { return readyLineCopy }
        return nil
    }

    /// The tally light. Derived from the label, never stored separately.
    public var isOnAir: Bool { onAirLabel != nil }

    /// Nothing to show (no station and no song).
    public var isEmpty: Bool { station == nil && track == nil }

    /// The surfaces' view of the playback snapshot and the DJ state. Reads only the station
    /// name, the current song's title and artist, the transport and `dj.onAirLabel`. The
    /// snapshot's `dj` line, queue, error and artwork URL are deliberately not read.
    public static func make(snapshot: PlaybackSnapshot, dj: DJStudioState) -> NowPlayingDisplay {
        let track = snapshot.nowPlaying
        let art: Art? = track.map { Art(StationArtStyle.track($0, on: snapshot.station)) }
            ?? snapshot.station.map { Art(StationArtStyle.station($0)) }
        let state: State = switch snapshot.transport {
        case .stopped: .stopped
        case .preparing: .starting
        case .playing: .playing
        case .paused: .paused
        }
        // On Air and Ready only while something is playing: a stopped player has no break coming.
        let live = state != .stopped
        return NowPlayingDisplay(station: snapshot.station?.name, track: track?.title, artist: track?.artistName,
                                 art: art, state: state,
                                 onAirLabel: live ? dj.onAirLabel : nil,
                                 readyLabel: live ? readyLabel(for: dj) : nil)
    }

    /// The copy written to the App Group for the widget. The widget's timeline cannot refresh
    /// within a 30-second break, so it never shows On Air or Ready (a stale tally or line would
    /// outlive the break, and a ready break can still become a quiet skip). The Live Activity,
    /// which updates live and is what StandBy shows full screen, carries both.
    public var widgetCopy: NowPlayingDisplay {
        NowPlayingDisplay(station: station, track: track, artist: artist, art: art, state: state,
                          onAirLabel: nil, readyLabel: nil)
    }

    /// Fields that are redacted while the device is locked (`.privacySensitive()`), per 04b.
    /// The clock, the state, the on-air dot and the ready line stay visible.
    public static let privacySensitiveFields: Set<String> = ["station", "track", "artist", "art"]
    /// Every encoded key. Anything outside this set must never be added without Sentinel.
    public static let allowedKeys: Set<String> = ["station", "track", "artist", "art", "state", "onAirLabel", "readyLabel"]
    public static let allowedArtKeys: Set<String> = ["hues", "saturation", "brightness", "monogram", "angle"]
}

// MARK: - App Group storage

/// The widget's shared copy: one JSON value under one key in the App Group's defaults.
public enum NowPlayingDisplayStore {
    public static let appGroupID = "group.com.aerodj"
    public static let defaultsKey = "onairly.nowPlayingDisplay.v1"
    /// `WidgetConfiguration` kind for the Now Playing / StandBy widget.
    public static let widgetKind = "OnAirlyNowPlaying"

    public static func encode(_ display: NowPlayingDisplay) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(display.widgetCopy)
    }

    /// Nil for missing or unreadable data; the widget then shows its empty state.
    public static func decode(_ data: Data?) -> NowPlayingDisplay? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(NowPlayingDisplay.self, from: data)
    }

    /// The widget needs a reload only when what it shows changes (not on every DJ state), so
    /// the WidgetKit reload budget is spent on song and station changes.
    public static func needsWidgetReload(from old: NowPlayingDisplay?, to new: NowPlayingDisplay) -> Bool {
        old?.widgetCopy != new.widgetCopy
    }
}

// MARK: - Live Activity plan

/// What the app does with the Live Activity for one display change. Pure, so the rules are
/// tested on Linux; the app performs the action fire-and-forget off the playback path.
public enum LiveActivityAction: Equatable, Sendable {
    case none
    case start(NowPlayingDisplay)
    case update(NowPlayingDisplay)
    case end
}

public enum LiveActivityPlan {
    /// - Parameters:
    ///   - previous: the last display sent to the activity (nil if none is running).
    ///   - isActive: a Live Activity from this app is running.
    ///   - appInForeground: ActivityKit only starts an activity from the foreground.
    ///   - activitiesEnabled: `ActivityAuthorizationInfo().areActivitiesEnabled`.
    public static func action(for display: NowPlayingDisplay, previous: NowPlayingDisplay?, isActive: Bool,
                              appInForeground: Bool, activitiesEnabled: Bool) -> LiveActivityAction {
        let wantsActivity = !display.isEmpty && (display.state == .playing || display.state == .paused
                                                 || display.state == .starting)
        if isActive {
            guard wantsActivity, activitiesEnabled else { return .end }
            return display == previous ? .none : .update(display)
        }
        guard wantsActivity, activitiesEnabled, appInForeground, display.state == .playing else { return .none }
        return .start(display)
    }
}

/// Lock-screen Live Activity layout. The system may truncate a presentation taller than
/// 160 pt; the content is built from these metrics and a test keeps the sum under it.
public enum LiveActivityLayout {
    public static let maxHeight: Double = 160
    public static let padding: Double = 14
    public static let headerHeight: Double = 20
    public static let rowSpacing: Double = 10
    public static let artSize: Double = 56
    /// Caption line for Ready ("DJ break after this song"). Budgeted even when absent, so
    /// showing it cannot push the lock presentation over the 160 pt cap.
    public static let readyLineHeight: Double = 16

    public static var contentHeight: Double {
        padding * 2 + headerHeight + rowSpacing + artSize + rowSpacing + readyLineHeight
    }
}
