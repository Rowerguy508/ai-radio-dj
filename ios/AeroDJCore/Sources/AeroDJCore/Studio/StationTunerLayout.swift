import Foundation

/// Pure layout decision for the Station Tuner (#461 PR 1).
///
/// On iPhone, closed Duo, Open-Duo Portrait, narrow Split View, `StudioLayout` Zone B, and
/// accessibility text sizes, `TuneForm` stays `.singleColumn` so existing phone and closed-Duo
/// snapshots remain byte-identical.
///
/// On Open-Duo Landscape (`820 × 640 pt`) and other wide landscape containers, `TuneForm`
/// switches to `.twoPane`: Sound controls on the left, DJ + Briefings + Recipes on the right,
/// a 32 pt fold-aligned center gutter straddling the device midpoint (`x = 410 pt` on open Duo),
/// and a 56 pt trailing vertical rail holding `Close` and `Save` (≥ 44 × 44 pt targets).
///
/// -Nova
public enum StationTunerLayout {
    /// Minimum container width to consider the horizontal two-pane tuner.
    public static let minWideWidth: Double = 700
    /// Minimum container height to consider the horizontal two-pane tuner.
    /// Excludes iPhone landscape (`844 × 390`, `956 × 440`) which stays `.singleColumn`.
    public static let minWideHeight: Double = 520
    /// Minimum width for each scrollable pane in `.twoPane` mode.
    public static let minPaneWidth: Double = 260
    /// Trailing vertical action rail width (`Close` / `Save`).
    public static let railWidth: Double = 56
    /// Center fold gutter width, centered on the device midpoint.
    public static let gutterWidth: Double = 32
    /// Target distance from the screen's leading edge to the Sound pane.
    public static let targetLeadingInset: Double = 24
    /// Target distance between the DJ pane and the trailing rail.
    public static let targetTrailingInset: Double = 20

    public enum Mode: String, Equatable, Sendable {
        case singleColumn
        case twoPane
    }

    public struct Input: Equatable, Sendable {
        public var containerWidth: Double
        public var containerHeight: Double
        public var accessibilityTextSize: Bool
        /// True when hosted inside `StudioLayout`'s Zone B (already a narrow side-by-side pane).
        public var isInSplitPane: Bool
        /// Horizontal outer padding already applied around `TuneForm` (e.g. `16 pt` inside
        /// `PlayingScreen`'s workspace sheet, `0` when full-bleed).
        public var outerHorizontalInset: Double
        /// Optional vertical fold center in window coordinates. When `nil`, defaults to the
        /// midpoint of the full window (`containerWidth / 2 + outerHorizontalInset`), which is
        /// `x = 410 pt` on an `820 × 640 pt` Open-Duo Landscape window.
        public var foldCenterX: Double?

        public init(containerWidth: Double,
                    containerHeight: Double,
                    accessibilityTextSize: Bool = false,
                    isInSplitPane: Bool = false,
                    outerHorizontalInset: Double = 0,
                    foldCenterX: Double? = nil) {
            self.containerWidth = containerWidth
            self.containerHeight = containerHeight
            self.accessibilityTextSize = accessibilityTextSize
            self.isInSplitPane = isInSplitPane
            self.outerHorizontalInset = outerHorizontalInset
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

        /// Gutter leading edge in local `TuneForm` coordinates.
        public var gutterMinX: Double { leadingPadding + leftPaneWidth }

        /// Gutter trailing edge in local `TuneForm` coordinates.
        public var gutterMaxX: Double { gutterMinX + gutterWidth }

        /// Gutter center in local `TuneForm` coordinates.
        public var gutterMidX: Double { gutterMinX + gutterWidth / 2 }

        /// Sum of all horizontal segments; equals `containerWidth` in `.twoPane` mode.
        public var totalWidth: Double {
            leadingPadding + leftPaneWidth + gutterWidth + rightPaneWidth + trailingPadding + railWidth
        }

        /// Compact diagnostic string for tests and captures.
        public var decisionText: String {
            switch mode {
            case .singleColumn:
                return "singleColumn"
            case .twoPane:
                return "twoPane \(Int(leftPaneWidth.rounded()))/\(Int(rightPaneWidth.rounded())) rail \(Int(railWidth.rounded()))"
            }
        }
    }

    /// Reference Open-Duo Landscape input (`820 × 640 pt`, full-bleed).
    public static let duoLandscape = Input(containerWidth: 820, containerHeight: 640)

    /// Reference Open-Duo Portrait input (`640 × 820 pt`, full-bleed).
    public static let duoPortrait = Input(containerWidth: 640, containerHeight: 820)

    /// Computes whether `TuneForm` should render as `.singleColumn` or `.twoPane`, and the
    /// exact pane + gutter + rail metrics when `.twoPane` is active.
    public static func decide(_ input: Input) -> Decision {
        let width = input.containerWidth
        let height = input.containerHeight
        let outer = max(0, input.outerHorizontalInset)
        let fullWindowWidth = width + outer * 2

        guard !input.accessibilityTextSize,
              !input.isInSplitPane,
              width.isFinite, height.isFinite,
              fullWindowWidth >= minWideWidth,
              height >= minWideHeight,
              fullWindowWidth > height else {
            return Decision(mode: .singleColumn)
        }

        let leading = max(0, targetLeadingInset - outer)
        let trailing = max(0, targetTrailingInset - outer)
        let windowMidX = input.foldCenterX ?? (fullWindowWidth / 2)
        let localFoldX = windowMidX - outer

        let left = localFoldX - leading - (gutterWidth / 2)
        let right = width - railWidth - leading - left - gutterWidth - trailing

        guard left >= minPaneWidth, right >= minPaneWidth else {
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
