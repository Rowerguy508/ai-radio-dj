import Foundation

// Pure, UI-framework-free rules the Studio screens render. They sit on top of the one
// `StudioPresentationModel` (#56) and Claude's `PlaybackSnapshot` (#58); they are not a
// second model. Everything here is a function of those inputs, so it is unit tested on
// Linux and the SwiftUI views stay thin. See docs/studio-ui.md.

// MARK: - Layout

/// The single source of truth for the closed/open (compact/Studio) switch and the zone
/// widths. The SwiftUI layout reads these values; nothing else picks a layout.
public enum StudioLayoutMetrics {
    public static let gutter: Double = 24
    public static let edgeInset: Double = 16
    public static let zoneAMinWidth: Double = 320
    public static let zoneBMinWidth: Double = 340
    public static let touchTargetMin: Double = 44
    /// Zone A + gutter + Zone B + both edge insets: 320 + 24 + 340 + 32 = 716.
    /// At exactly this width each zone gets its minimum, never less (#60 review P1).
    public static var studioMinWidth: Double { zoneAMinWidth + gutter + zoneBMinWidth + edgeInset * 2 }
    /// Below this container height Zone A drops artwork to 120 pt and keeps transport.
    public static let lowHeight: Double = 480

    /// Visual only: the outer margin the unfolded Studio actually draws. Smaller than
    /// `edgeInset`, so the two panes run close to edge to edge. `edgeInset` and `gutter`
    /// still define `studioMinWidth`, so the compact/Studio switch does not move.
    public static let paneEdgeInset: Double = 8
    /// Visual only: the space the unfolded Studio draws between the panes, centred in the container.
    public static let paneGutter: Double = 12
}

/// Continuous corner radii for the unfolded Studio (owner request, 2026-10-28). One token,
/// so the panes, the cards inside them and the field nest evenly. The compact layout keeps
/// its own radii.
public enum StudioCornerRadius {
    /// Zone A (art and player card) and Zone B (the workspace panel).
    public static let panel: Double = 30
    /// Cards inside the workspace (Genres, Mood, Connections sources, recipes).
    public static let card: Double = 22
    /// Text fields inside those cards ("Add your own").
    public static let field: Double = 14
    /// Padding between the panel edge and its cards.
    public static let panelPadding: Double = 16
}

/// Which layout a container gets. Width is the only input besides text size and, in the
/// screen's rule, whether the width class is regular: no device model, no fold sensor.
/// Folding just changes the container width.
public enum StudioLayoutMode: Equatable, Sendable {
    /// Closed Duo, or any container narrower than `studioMinWidth`.
    case compact
    /// Open Duo: Zone A (Now Playing) and Zone B (workspace) side by side.
    case studio
    /// Open, but at an accessibility text size: the two zones stack in one scroll view.
    case studioStacked

    public static func resolve(containerWidth: Double, accessibilityTextSize: Bool) -> StudioLayoutMode {
        guard containerWidth >= StudioLayoutMetrics.studioMinWidth else { return .compact }
        return accessibilityTextSize ? .studioStacked : .studio
    }

    /// The screen's full rule: the width class gates the Studio, then the width rule above.
    /// Pass `horizontalSizeClass == .regular`, never `!= .compact`, so a missing size class
    /// (nil, UIKit's `unspecified`) takes the compact layout. The 716 pt threshold is unchanged.
    public static func resolve(hasRegularWidth: Bool, containerWidth: Double,
                               accessibilityTextSize: Bool) -> StudioLayoutMode {
        guard hasRegularWidth else { return .compact }
        return resolve(containerWidth: containerWidth, accessibilityTextSize: accessibilityTextSize)
    }
}

/// Widths actually given to the two zones. The split is an even split of the available
/// width whenever both minimums allow it, so the gutter straddles the middle of the
/// container. That is not a promise it sits over a Duo's hinge: a vertical bar or a sidebar
/// can shift or narrow the container. Near the breakpoint each zone gets at least its
/// minimum and Zone B takes the rest.
public struct StudioZoneWidths: Equatable, Sendable {
    public let zoneA: Double
    public let zoneB: Double
    /// The outer margin and gutter these widths were allocated with. The view draws exactly
    /// these, so `edgeInset * 2 + gutter + zoneA + zoneB` is always the container width.
    public let edgeInset: Double
    public let gutter: Double

    public init(zoneA: Double, zoneB: Double,
                edgeInset: Double = StudioLayoutMetrics.edgeInset,
                gutter: Double = StudioLayoutMetrics.gutter) {
        self.zoneA = zoneA
        self.zoneB = zoneB
        self.edgeInset = edgeInset
        self.gutter = gutter
    }

    /// `nil` when the container is too narrow for Studio (the compact layout applies).
    /// The switch always uses `studioMinWidth`. `edgeInset` and `gutter` only change how
    /// the width is drawn: any width they free up goes to the zones.
    public static func allocate(containerWidth: Double,
                                edgeInset: Double = StudioLayoutMetrics.edgeInset,
                                gutter: Double = StudioLayoutMetrics.gutter) -> StudioZoneWidths? {
        let m = StudioLayoutMetrics.self
        guard containerWidth >= m.studioMinWidth else { return nil }
        let content = containerWidth - edgeInset * 2 - gutter
        let a = max(m.zoneAMinWidth, min((content / 2).rounded(.down), content - m.zoneBMinWidth))
        return StudioZoneWidths(zoneA: a, zoneB: content - a, edgeInset: edgeInset, gutter: gutter)
    }

    /// The unfolded Studio as drawn: `paneEdgeInset` and `paneGutter`, same switch.
    public static func allocatePanes(containerWidth: Double) -> StudioZoneWidths? {
        allocate(containerWidth: containerWidth,
                 edgeInset: StudioLayoutMetrics.paneEdgeInset,
                 gutter: StudioLayoutMetrics.paneGutter)
    }

    /// Artwork side in Zone A: min(zone width − 16, 360, 44% of the height). Zone A is not a
    /// card, so the artwork may use nearly its full width; the height budget keeps the track
    /// block and transport on screen.
    public func artworkSide(containerHeight: Double) -> Double {
        if containerHeight < StudioLayoutMetrics.lowHeight { return 120 }
        let budget = (containerHeight * 0.44).rounded(.down)
        return max(120, min(zoneA - 16, 360, budget))
    }
}

// MARK: - Playback screen state

/// Apple Music access as the app's session reports it (`MusicKitService.authState`).
public enum PlaybackAccess: Equatable, Sendable {
    case checking
    /// Status is `.notDetermined`: show Allow (never the bare Connecting spinner).
    case needsAuthorization
    case authorized
    case denied
    case subscriptionRequired
}

/// What the Now Playing area may show. Transport appears only when there is a session the
/// buttons can actually control.
public enum NowPlayingContent: Equatable, Sendable {
    /// "Connecting to Apple Music". No transport.
    case connecting
    /// Status still `.notDetermined`. Named Allow button → `authorize()`; never a bare spinner.
    case needsAuthorization
    /// Access was denied. The only real fix is Settings (the system won't prompt twice).
    case accessDenied
    /// "An Apple Music subscription is required." No retry, no transport.
    case subscriptionRequired
    /// Authorized, nothing queued: offer the real Apple Music search to start listening.
    case nothingPlaying
    /// A track is loaded (playing or paused).
    case track(TrackInfo)

    public static func resolve(access: PlaybackAccess, snapshot: PlaybackSnapshot) -> NowPlayingContent {
        switch access {
        case .checking: return .connecting
        case .needsAuthorization: return .needsAuthorization
        case .denied: return .accessDenied
        case .subscriptionRequired: return .subscriptionRequired
        case .authorized:
            if let track = snapshot.nowPlaying { return .track(track) }
            return .nothingPlaying
        }
    }

    public var showsTransport: Bool { if case .track = self { true } else { false } }

    public var title: String {
        switch self {
        case .connecting: "Connecting to Apple Music"
        case .needsAuthorization: "Allow Apple Music to play your station."
        case .accessDenied: "Apple Music access is off"
        case .subscriptionRequired: "An Apple Music subscription is required"
        case .nothingPlaying: "Nothing playing"
        case .track(let t): t.title
        }
    }

    public var detail: String? {
        switch self {
        case .connecting: nil
        case .needsAuthorization: "AeroDJ needs permission before it can play from Apple Music."
        case .accessDenied: "Allow Apple Music for AeroDJ in Settings to play your station."
        case .subscriptionRequired: "AeroDJ plays music through your Apple Music subscription."
        case .nothingPlaying: "Search Apple Music to start your station."
        case .track: nil
        }
    }
}

// MARK: - Playback errors

/// The only things an error banner button may do. Each maps to a real call.
public enum PlaybackErrorAction: Equatable, Sendable {
    /// `MusicKitService.authorize()` (system prompt).
    case requestAuthorization
    /// Try playback again: `resume()`, then dismiss.
    case retry
    case dismiss
}

public struct PlaybackErrorPresentation: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// Inline card above the transport.
        case banner
        /// Subtle caption; music continues. Never a modal (speech failures).
        case caption
    }

    public let style: Style
    public let title: String
    public let primary: PlaybackErrorAction?
    public let dismissible: Bool

    /// ui-contract.md §9. `nil` when there is no error.
    public init?(_ error: PlaybackError?) {
        guard let error else { return nil }
        switch error.kind {
        case .notAuthorized:
            self.init(style: .banner, title: "Allow Apple Music to play your station.",
                      primary: .requestAuthorization, dismissible: false)
        case .subscriptionRequired:
            self.init(style: .banner, title: "An Apple Music subscription is required.", primary: nil, dismissible: false)
        case .resumeFailed:
            self.init(style: .banner, title: error.message, primary: .retry, dismissible: true)
        case .playbackFailed:
            self.init(style: .banner, title: error.message, primary: error.isRecoverable ? .retry : nil, dismissible: true)
        case .speechFailed:
            self.init(style: .caption, title: "DJ voice unavailable. Music continues.", primary: nil, dismissible: false)
        }
    }

    private init(style: Style, title: String, primary: PlaybackErrorAction?, dismissible: Bool) {
        self.style = style
        self.title = title
        self.primary = primary
        self.dismissible = dismissible
    }

    public var primaryTitle: String? {
        switch primary {
        case .requestAuthorization: "Allow"
        case .retry: "Try again"
        case .dismiss: "Dismiss"
        case nil: nil
        }
    }
}

// MARK: - DJ status

/// What the DJ line may show. Built from `StudioPresentationModel.djState` only. It never
/// reads `PlaybackSnapshot.dj` (a second DJ state that carries line text).
///
/// - "On Air" appears only in `.speaking`, which comes only from the player's confirmed
///   `playbackStarted`. No other state is labeled On Air or LIVE.
/// - No caption, transcript, waveform or level meter: the contract exposes no clip text.
public struct DJStatusPresentation: Equatable, Sendable {
    public let state: DJStudioState
    /// "On Air" or `nil`.
    public let onAirBadge: String?
    /// One short status line, or `nil` when there is nothing true to say (idle).
    public let headline: String?
    /// Shared items waiting for review; the line becomes a button to the review list.
    public let reviewCount: Int?
    /// Whether anything may animate. True only while On Air.
    public var animatesActivity: Bool { state.isOnAir }
    public let accessibilityLabel: String

    public init(state: DJStudioState) {
        self.state = state
        self.onAirBadge = state.onAirLabel
        switch state {
        case .idle:
            headline = nil
            reviewCount = nil
        case .preparing(let briefing):
            headline = briefing ? "Preparing your briefing" : "Preparing a DJ break"
            reviewCount = nil
        case .ready(let briefing, _):
            headline = briefing ? "Briefing after this song" : "DJ break after this song"
            reviewCount = nil
        case .speaking(let briefing):
            headline = briefing ? "Briefing" : "DJ"
            reviewCount = nil
        case .failed(.consentReviewRequired(let n)):
            headline = "\(n) to review"
            reviewCount = n
        case .failed(.voiceFailed):
            headline = "DJ voice unavailable"
            reviewCount = nil
        case .failed(.budgetReached):
            headline = "DJ voice limit reached"
            reviewCount = nil
        }
        accessibilityLabel = state == .idle ? "" : state.detail
    }
}

// MARK: - Connections

/// What a Connections button does in the UI. Every offered `ConnectionAction` maps to a
/// real handler or to an explicit "not available" explanation; none is a no-op.
public enum ConnectionActionRoute: Equatable, Sendable {
    /// `ConnectionsModel.perform(_:onSource:)` / `perform(_:on:)`.
    case model
    /// Open the iOS Settings page for AeroDJ, then `refresh()`.
    case systemSettings
    /// The in-app calendar picker over `calendar.calendars`, then `selectCalendars(_:)`.
    case calendarPicker
    /// The item list for this source (review, approve, read anyway, revoke, delete).
    case itemReview
    /// The system file picker for `.md` files; picks are stored as security-scoped bookmarks.
    case filePicker
    /// Shown as disabled text with this reason. No button.
    case unavailable(String)
}

/// Capabilities the running build actually has. The UI routes by these, so a missing
/// picker shows as "not available", never as a button that does nothing.
public struct ConnectionUICapabilities: Equatable, Sendable {
    /// A document picker that persists security-scoped bookmarks for Obsidian files.
    public var canPickObsidianFiles: Bool

    public init(canPickObsidianFiles: Bool) { self.canPickObsidianFiles = canPickObsidianFiles }

    /// Without a file reader (previews, the test station): no picker. The live app passes
    /// `canPickObsidianFiles: true` when its composition has one (`ConnectionsComposition.notes`).
    public static let current = ConnectionUICapabilities(canPickObsidianFiles: false)

    public static let obsidianPickerUnavailable = "Choosing notes isn't available here."

    public func route(_ action: ConnectionAction, onSource integration: StationIntegration) -> ConnectionActionRoute {
        switch action {
        case .allowAccess, .revoke: return .model
        case .openSettings: return .systemSettings
        case .reselect:
            switch integration {
            case .calendar: return .calendarPicker
            case .obsidian: return canPickObsidianFiles ? .filePicker : .unavailable(Self.obsidianPickerUnavailable)
            case .shareInbox: return .itemReview
            }
        case .review: return .itemReview
        case .approve, .readAnyway, .delete: return .model
        }
    }
}

public extension ConnectionSourceRow {
    /// The badge text. "Connected" only when `mayShowConnected`; never inferred from a request.
    var badge: String? {
        if mayShowConnected { return "Connected" }
        switch status {
        case .off: return "Off"
        case .checking: return "Checking"
        case .consentReviewRequired: return "Needs permission"
        case .blocked(let consent):
            switch consent {
            case .denied: return "Access off"
            case .revoked: return "Stopped"
            case .notRequested, .granted: return "Permission off"
            }
        case .on: return nil
        }
    }

    /// Share items waiting for review, for the "Review" entry under Shared from Mail & Messages.
    var reviewableItemCount: Int {
        if case .sharedImports(let s) = detail { return s.waitingForReview + s.approved }
        return 0
    }
}

// MARK: - Station Tuner

public enum StationTunerCopy {
    /// Honest footnote: tuning is saved and applied at boundaries, but no song picker reads it
    /// yet. Music comes from what the listener starts in Apple Music.
    public static let musicSelectionNotice =
        "Saved with your station. Song picking doesn't use these settings yet; music comes from what you start in Apple Music."
    public static let pendingHeader = "Waiting for a safe moment"
    public static let unsavedHeader = "Unsaved changes"
    /// Truthful about idle vs holding: idle Save applies now; a held song waits for the boundary.
    public static func unsavedDetail(idle: Bool) -> String {
        idle
            ? "Nothing is playing. Save applies these now."
            : "Save keeps them until the next safe moment. The song that is playing is not changed."
    }
    public static func nowUsing(_ summary: String) -> String { "Now using: \(summary)" }
}

public extension StationTunerRow {
    /// "Applies after this song" etc., plus what is in effect now, for VoiceOver.
    var accessibilitySummary: String {
        if let appliesCopy {
            return "\(title): \(displayedSummary). \(appliesCopy). \(StationTunerCopy.nowUsing(activeSummary))."
        }
        return "\(title): \(displayedSummary)."
    }
}

// MARK: - Tuner indicators

/// The one indicator each tuner control shows: saved, pending or active (plus saving,
/// consent and error states). "Active" is used only for settings something actually reads
/// today; settings nothing reads yet (genres, mood, energy, discovery) say "Saved".
public enum TunerIndicator: Equatable, Sendable {
    /// Saved, and nothing reads it yet. Honest: song picking doesn't use these settings.
    case saved
    /// Saved, waiting for a safe moment (copy says when).
    case pending(String)
    /// Saved and in effect for what reads it (DJ breaks, briefings).
    case active
    case saving
    /// Requested but consent isn't granted; nothing is read.
    case needsConsent(String)
    case problem(String)

    public init(status: StationControlStatus, setting: StationSetting) {
        switch status {
        case .idle: self = setting.isReadToday ? .active : .saved
        case .saving: self = .saving
        case .pendingBoundary(let timing): self = .pending(timing.appliesCopy)
        case .consentRequired(.granted): self = setting.isReadToday ? .active : .saved
        case .consentRequired(.denied): self = .needsConsent("Access is off")
        case .consentRequired(.revoked): self = .needsConsent("Revoked")
        case .consentRequired(.notRequested): self = .needsConsent("Needs permission")
        case .error(.notLoaded): self = .problem("Loading")
        case .error(.readOnlyNewerVersion): self = .problem("Read-only")
        case .error(.saveFailed): self = .problem("Couldn't save")
        case .error(.reductionNotSaved): self = .problem("Will save with next change")
        }
    }

    public var label: String {
        switch self {
        case .saved: "Saved"
        case .pending: "Pending"
        case .active: "Active"
        case .saving: "Saving…"
        case .needsConsent(let s), .problem(let s): s
        }
    }

    /// Longer VoiceOver text.
    public var accessibilityLabel: String {
        switch self {
        case .saved: "Saved. Song picking doesn't use this yet."
        case .pending(let copy): "Pending. \(copy)."
        case .active: "Active."
        default: label + "."
        }
    }
}

public extension StationSetting {
    /// Whether anything in the app reads this setting today. Tuning for song picking is
    /// stored and applied at boundaries but no selection engine reads it yet.
    var isReadToday: Bool {
        switch self {
        case .genres, .moods, .energy, .discovery, .seeds, .reach: false
        case .commentary, .personality, .briefing, .integration: true
        }
    }

    /// One honest line on what the setting changes today.
    var usageCopy: String {
        switch self {
        case .genres, .moods, .energy, .discovery, .seeds, .reach: "Saved with your station. Not used for song picking yet."
        case .commentary: "Changes how often the DJ talks between songs."
        case .personality: "Changes how long a DJ break may be."
        case .briefing: "Lets DJ breaks carry your briefing."
        case .integration: "Read only with your consent, in Connections."
        }
    }
}
