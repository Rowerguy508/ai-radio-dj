import Foundation

/// Pure layout decision for the Open-Duo Landscape Master-Detail Settings screen (#461 PR 2).
///
/// On iPhone, closed Duo, Open-Duo Portrait (`640 × 820 pt`), narrow Split View, split-bar slices,
/// and accessibility text sizes, `SettingsView` stays `.singleColumn` so existing phone, closed-Duo,
/// and Duo-portrait snapshots remain byte-identical.
///
/// On Open-Duo Landscape (`820 × 640 pt`) and other wide landscape containers, `SettingsView`
/// switches to `.masterDetail`: category list on the left, selected category's controls on the
/// right, a 32 pt fold-aligned center gutter straddling the device midpoint (`x = 410 pt`), and
/// a 56 pt trailing vertical rail holding `Done` (≥ 44 × 44 pt target).
///
/// -Nova
public enum SettingsMasterDetailLayout {
    public static let minWideWidth: Double = 700
    public static let minWideHeight: Double = 520
    public static let minMasterWidth: Double = 240
    public static let minDetailWidth: Double = 260
    public static let railWidth: Double = 56
    public static let gutterWidth: Double = 32
    public static let targetLeadingInset: Double = 24
    public static let targetTrailingInset: Double = 20

    public enum Mode: String, Equatable, Sendable {
        case singleColumn
        case masterDetail
    }

    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case playback
        case stationsLayout
        case ratings
        case privacy

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .playback: return "Playback & DJ"
            case .stationsLayout: return "Stations layout"
            case .ratings: return "Ratings"
            case .privacy: return "Data & Privacy"
            }
        }

        public var subtitle: String {
            switch self {
            case .playback: return "Talk-over & fades"
            case .stationsLayout: return "Open Duo layout"
            case .ratings: return "Liked & skipped songs"
            case .privacy: return "Delete DJ data"
            }
        }

        public var systemImage: String {
            switch self {
            case .playback: return "waveform"
            case .stationsLayout: return "square.grid.2x2"
            case .ratings: return "hand.thumbsup"
            case .privacy: return "trash"
            }
        }
    }

    public struct Input: Equatable, Sendable {
        public var containerWidth: Double
        public var containerHeight: Double
        public var accessibilityTextSize: Bool
        /// True when `SplitBarHost` supplies split-view insets (narrow/split slices stay single-column).
        public var hasSplitInsets: Bool
        /// Optional vertical fold center in container coordinates; defaults to `containerWidth / 2`
        /// (`x = 410 pt` on an `820 × 640 pt` Open-Duo Landscape window).
        public var foldCenterX: Double?

        public init(containerWidth: Double,
                    containerHeight: Double,
                    accessibilityTextSize: Bool = false,
                    hasSplitInsets: Bool = false,
                    foldCenterX: Double? = nil) {
            self.containerWidth = containerWidth
            self.containerHeight = containerHeight
            self.accessibilityTextSize = accessibilityTextSize
            self.hasSplitInsets = hasSplitInsets
            self.foldCenterX = foldCenterX
        }
    }

    public struct Decision: Equatable, Sendable {
        public let mode: Mode
        public let leadingPadding: Double
        public let masterWidth: Double
        public let gutterWidth: Double
        public let detailWidth: Double
        public let trailingPadding: Double
        public let railWidth: Double

        public init(mode: Mode,
                    leadingPadding: Double = 0,
                    masterWidth: Double = 0,
                    gutterWidth: Double = 0,
                    detailWidth: Double = 0,
                    trailingPadding: Double = 0,
                    railWidth: Double = 0) {
            self.mode = mode
            self.leadingPadding = leadingPadding
            self.masterWidth = masterWidth
            self.gutterWidth = gutterWidth
            self.detailWidth = detailWidth
            self.trailingPadding = trailingPadding
            self.railWidth = railWidth
        }

        public var gutterMinX: Double { leadingPadding + masterWidth }
        public var gutterMaxX: Double { gutterMinX + gutterWidth }
        public var gutterMidX: Double { gutterMinX + gutterWidth / 2 }
        public var totalWidth: Double {
            leadingPadding + masterWidth + gutterWidth + detailWidth + trailingPadding + railWidth
        }

        public var decisionText: String {
            switch mode {
            case .singleColumn:
                return "singleColumn"
            case .masterDetail:
                return "masterDetail \(Int(masterWidth.rounded()))/\(Int(detailWidth.rounded())) rail \(Int(railWidth.rounded()))"
            }
        }
    }

    public static let duoLandscape = Input(containerWidth: 820, containerHeight: 640)
    public static let duoPortrait = Input(containerWidth: 640, containerHeight: 820)

    /// Visible categories for the current environment.
    public static func availableCategories(hasRatings: Bool, hasPersonalDataReset: Bool) -> [Category] {
        var list: [Category] = [.playback, .stationsLayout]
        if hasRatings { list.append(.ratings) }
        if hasPersonalDataReset { list.append(.privacy) }
        return list
    }

    /// Ensures the selected category is present in the available list.
    public static func resolvedSelection(_ current: Category,
                                         hasRatings: Bool,
                                         hasPersonalDataReset: Bool) -> Category {
        let available = availableCategories(hasRatings: hasRatings, hasPersonalDataReset: hasPersonalDataReset)
        return available.contains(current) ? current : .playback
    }

    public static func decide(_ input: Input) -> Decision {
        let width = input.containerWidth
        let height = input.containerHeight

        guard !input.accessibilityTextSize,
              !input.hasSplitInsets,
              width.isFinite, height.isFinite,
              width >= minWideWidth,
              height >= minWideHeight,
              width > height else {
            return Decision(mode: .singleColumn)
        }

        let leading = targetLeadingInset
        let trailing = targetTrailingInset
        let foldX = input.foldCenterX ?? (width / 2)

        let master = foldX - leading - (gutterWidth / 2)
        let detail = width - railWidth - leading - master - gutterWidth - trailing

        guard master >= minMasterWidth, detail >= minDetailWidth else {
            return Decision(mode: .singleColumn)
        }

        return Decision(mode: .masterDetail,
                        leadingPadding: leading,
                        masterWidth: master,
                        gutterWidth: gutterWidth,
                        detailWidth: detail,
                        trailingPadding: trailing,
                        railWidth: railWidth)
    }
}
