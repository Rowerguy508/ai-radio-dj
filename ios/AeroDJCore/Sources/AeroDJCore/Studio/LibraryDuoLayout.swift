import Foundation

/// Pure layout decision for the Open-Duo Landscape horizontal Library / Add-Station picker
/// (#461 PR 3, mockup `02-library-duo.png`).
///
/// On iPhone, closed Duo, Open-Duo Portrait (`640 × 820 pt`), narrow Split View, split-bar slices,
/// and accessibility text sizes, `AddStationWalkthroughView` stays `.singleColumn` so existing
/// phone, closed-Duo, and Duo-portrait (`duoWideLibrary`) snapshots remain byte-identical.
///
/// On Open-Duo Landscape (`820 × 640 pt`) and other wide landscape containers, it switches to
/// `.twoPane`: controls / search / source picker / selected chips on the left, scrollable results
/// or step choices on the right, a 32 pt center gutter aligned to device midpoint (`x = 410 pt`),
/// and a 56 pt trailing action rail holding `Cancel`/`Done`, `Back`, and `Next`/`Save` (≥ 44 × 44 pt).
///
/// -Nova
public enum LibraryDuoLayout {
    public static let minWideWidth: Double = 700
    public static let minWideHeight: Double = 520
    public static let minLeftWidth: Double = 260
    public static let minRightWidth: Double = 260
    public static let railWidth: Double = 56
    public static let gutterWidth: Double = 32
    public static let targetLeadingInset: Double = 24
    public static let targetTrailingInset: Double = 20

    public enum Mode: String, Equatable, Sendable {
        case singleColumn
        case twoPane
    }

    public struct Input: Equatable, Sendable {
        public var containerWidth: Double
        public var containerHeight: Double
        public var accessibilityTextSize: Bool
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
        public let leftPaneWidth: Double
        public let gutterWidth: Double
        public let rightPaneWidth: Double
        public let trailingPadding: Double
        public let railWidth: Double

        public init(mode: Mode,
                    leadingPadding: Double = 0,
                    leftPaneWidth: Double = 0,
                    gutterWidth: Double = 0,
                    rightPaneWidth: Double = 0,
                    trailingPadding: Double = 0,
                    railWidth: Double = 0) {
            self.mode = mode
            self.leadingPadding = leadingPadding
            self.leftPaneWidth = leftPaneWidth
            self.gutterWidth = gutterWidth
            self.rightPaneWidth = rightPaneWidth
            self.trailingPadding = trailingPadding
            self.railWidth = railWidth
        }

        public var gutterMinX: Double { leadingPadding + leftPaneWidth }
        public var gutterMaxX: Double { gutterMinX + gutterWidth }
        public var gutterMidX: Double { gutterMinX + gutterWidth / 2 }
        public var totalWidth: Double {
            leadingPadding + leftPaneWidth + gutterWidth + rightPaneWidth + trailingPadding + railWidth
        }

        public var decisionText: String {
            switch mode {
            case .singleColumn:
                return "singleColumn"
            case .twoPane:
                return "twoPane \(Int(leftPaneWidth.rounded()))/\(Int(rightPaneWidth.rounded())) rail \(Int(railWidth.rounded()))"
            }
        }
    }

    public static let duoLandscape = Input(containerWidth: 820, containerHeight: 640)
    public static let duoPortrait = Input(containerWidth: 640, containerHeight: 820)

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

        let left = foldX - leading - (gutterWidth / 2)
        let right = width - railWidth - leading - left - gutterWidth - trailing

        guard left >= minLeftWidth, right >= minRightWidth else {
            return Decision(mode: .singleColumn)
        }

        return Decision(mode: .twoPane,
                        leadingPadding: leading,
                        leftPaneWidth: left,
                        gutterWidth: gutterWidth,
                        rightPaneWidth: right,
                        trailingPadding: trailing,
                        railWidth: railWidth)
    }
}
