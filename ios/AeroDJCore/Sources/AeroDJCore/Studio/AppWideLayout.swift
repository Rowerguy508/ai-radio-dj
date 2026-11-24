import Foundation

/// #465 item 10 (folds into #461): Library, Stations and Settings on wide containers, the
/// unfolded Duo's inner display (640 × 820 pt, compact class), iPad, and Split View. One
/// decision for every screen, so the breakpoints live in one place and are unit tested.
///
/// Inputs are the width class and the container only, never a device model or the hinge.
/// A missing width class is passed as `hasRegularWidth: false`.
///
/// **Phone path.** Anything under `FoldedColumnLayout.wideMinWidth`, and any compact-class
/// container shorter than `FoldedColumnLayout.duoMinHeight` (every iPhone in landscape), is
/// `.phone`. Callers render the screen exactly as before for `.phone`: no inset, one column,
/// nothing measured differently. Narrow Split View (340 pt) is the phone path too.
///
/// **Seams.** `foldDivision` (item 2, fold awareness) and `arrangement` (item 4, the
/// `ArrangementView` two-pane layout) are slots that default to nil and change nothing yet,
/// so those PRs plug in here instead of each screen growing its own check.
///
/// Pure and UI-free so it is unit tested on Linux. Points of the container, never a device.
public enum AppWideLayout {
    /// The screens item 10 covers. Onboarding is the first-run prompts that are ours
    /// (`LocalAreaPrompt`; the cloud-voice consent sheet after #478). The Allow screen is #479's.
    public enum Screen: String, CaseIterable, Equatable, Sendable {
        case library
        case stations
        case settings
        case onboarding
    }

    /// #465 item 2: one `reservedRegions(kind: .division)` region in the container's
    /// points, aliased directly to `FoldAwareness.Division` so `FoldDivisionProbe` feeds
    /// `Input.foldDivision` with no conversion.
    public typealias FoldDivision = FoldAwareness.Division

    /// What `ArrangementView` gives the screen (#465 item 4): `ArrangementPaneLayout.Decision`
    /// maps onto it with `appWideArrangement` (`.split` is `.twoPane`, `.singleColumn` is
    /// `.single`, `.unchanged` is nil). Carried, not read yet: every screen ignores it, and
    /// nil (the default) is today's behaviour.
    public enum Arrangement: Equatable, Sendable {
        case single
        case twoPane
    }

    /// Everything the decision reads. Build one per screen from the environment and the
    /// container's measured size.
    public struct Input: Equatable, Sendable {
        public var hasRegularWidth: Bool
        public var containerWidth: Double
        public var containerHeight: Double
        public var accessibilityTextSize: Bool
        /// The vertical size class (`verticalSizeClass == .regular`). Decides a regular-width
        /// container: Plus and Max iPhones in landscape are regular width but vertically
        /// compact, and stay the phone path; the iPad (any orientation, form sheets, Split
        /// View) is vertically regular. Nil falls back to `containerHeight >= duoMinHeight`.
        public var hasRegularHeight: Bool?
        /// Only for a screen whose measured height is its own content, not the window
        /// (`LocalAreaPrompt`, a medium-detent sheet). The height test can't tell the Duo
        /// from a phone then, so `hasRegularHeight` alone decides for both width classes
        /// (missing counts as compact). Every iPhone in landscape, Plus and Max included, is
        /// vertically compact and stays the phone path (#515 B1).
        public var heightIsContent: Bool
        /// #465 item 2: active vertical fold division from `FoldDivisionProbe`, or nil.
        public var foldDivision: FoldDivision?
        /// `ArrangementPaneLayout.Decision.appWideArrangement` for this container. Ignored today.
        public var arrangement: Arrangement?

        public init(hasRegularWidth: Bool, containerWidth: Double, containerHeight: Double,
                    accessibilityTextSize: Bool = false, hasRegularHeight: Bool? = nil,
                    heightIsContent: Bool = false,
                    foldDivision: FoldDivision? = nil, arrangement: Arrangement? = nil) {
            self.hasRegularWidth = hasRegularWidth
            self.containerWidth = containerWidth
            self.containerHeight = containerHeight
            self.accessibilityTextSize = accessibilityTextSize
            self.hasRegularHeight = hasRegularHeight
            self.heightIsContent = heightIsContent
            self.foldDivision = foldDivision
            self.arrangement = arrangement
        }
    }

    public enum Mode: Equatable, Sendable {
        /// Today's screen, unchanged. Every iPhone, portrait or landscape, and narrow Split View.
        case phone
        /// The Duo's inner display, iPad, and Split View half and wider.
        case wide

        public var name: String {
            switch self {
            case .phone: "phone"
            case .wide: "wide"
            }
        }
    }

    public struct Decision: Equatable, Sendable {
        public var mode: Mode
        /// Symmetric inset when `leadingInset == trailingInset`, otherwise `min(leadingInset, trailingInset)`.
        /// Zero on the phone path.
        public var sideInset: Double
        /// Inset added on the leading edge on top of the screen's own gutter. Zero on the phone path.
        public var leadingInset: Double
        /// Inset added on the trailing edge on top of the screen's own gutter. Zero on the phone path.
        public var trailingInset: Double
        /// The content's width after `leadingInset` and `trailingInset` (the screen's own gutter
        /// is still inside it). The container width on the phone path.
        public var readableWidth: Double
        /// Columns the screen's list or grid uses. 1 on the phone path, so a caller that
        /// sees 1 keeps its single-column view.
        public var columns: Int
        public var gutter: Double

        public init(mode: Mode, sideInset: Double, readableWidth: Double, columns: Int, gutter: Double) {
            self.mode = mode
            self.sideInset = sideInset
            self.leadingInset = sideInset
            self.trailingInset = sideInset
            self.readableWidth = readableWidth
            self.columns = columns
            self.gutter = gutter
        }

        public init(mode: Mode, leadingInset: Double, trailingInset: Double,
                    readableWidth: Double, columns: Int, gutter: Double) {
            self.mode = mode
            self.sideInset = min(leadingInset, trailingInset)
            self.leadingInset = leadingInset
            self.trailingInset = trailingInset
            self.readableWidth = readableWidth
            self.columns = columns
            self.gutter = gutter
        }

        public var adapts: Bool { mode == .wide }

        /// Debug readout for captures and UI tests: "wide 2 40" when symmetric.
        public var decisionText: String {
            if abs(leadingInset - trailingInset) < 0.5 {
                return "\(mode.name) \(columns) \(Int(sideInset.rounded()))"
            }
            return "\(mode.name) \(columns) \(Int(leadingInset.rounded()))/\(Int(trailingInset.rounded()))"
        }
    }

    /// Readable caps, including the screen's own gutter. Library and Settings are reading
    /// columns. Stations is a grid of cards, so it may use more of the width.
    public static func readableMaxWidth(_ screen: Screen) -> Double {
        switch screen {
        case .library: 560
        case .settings: 560
        case .onboarding: 560
        case .stations: 960
        }
    }

    /// The gutter each screen already draws (`AddStationWalkthroughView` pads 20; a Form's
    /// inset group is 20; the station grid uses 16). Columns are counted inside it.
    public static func screenGutter(_ screen: Screen) -> Double {
        switch screen {
        case .library, .settings: 20
        // `LocalAreaPrompt` pads 24.
        case .onboarding: 24
        case .stations: 16
        }
    }

    /// Narrowest column a list or grid splits into. Under two of these (plus the gutter)
    /// the screen keeps one column.
    public static func minColumnWidth(_ screen: Screen) -> Double {
        switch screen {
        case .library: 240
        case .stations: 180
        // One column: Settings rows are short toggles and buttons with long footers;
        // two columns of Form sections read worse than one readable column.
        case .settings, .onboarding: .infinity
        }
    }

    public static let maxColumns = 4
    public static let columnGutter: Double = 16

    /// True when the container is wide enough to adapt. See the type comment for the phone path.
    public static func isWide(_ input: Input) -> Bool {
        let width = finite(input.containerWidth)
        let height = finite(input.containerHeight)
        if input.heightIsContent {
            guard FoldedColumnLayout.isWide(containerWidth: width) else { return false }
            return input.hasRegularHeight ?? false
        }
        guard FoldedColumnLayout.isWide(containerWidth: width), height > 0 else { return false }
        let tall = height >= FoldedColumnLayout.duoMinHeight
        // Regular width (#512 B1): wide only when the height is regular too. The vertical
        // size class, not the measured height: an iPad form sheet (540 × 620) is short but
        // vertically regular, and a Plus or Max iPhone in landscape (956 × 440, regular
        // width) is vertically compact. A size class doesn't depend on what is measured.
        if input.hasRegularWidth { return input.hasRegularHeight ?? tall }
        // Compact and short is a phone on its side (at most 430 pt tall), or the 652 × 680
        // compact-to-regular probe, which is vertically regular on an iPad, so compact
        // width keeps the height test. The unfolded Duo (640 × 820) passes it.
        return tall
    }

    /// Picks the active vertical fold division for an app-wide container in book pose (#465 item 2).
    /// Matches `FoldAwareness`: closed or fully open hinges return nil, horizontal (laptop) divisions
    /// and inactive or short regions return nil, and hinge angle is never read.
    public static func activeBookFold(in divisions: [FoldDivision],
                                      hinge: FoldAwareness.HingeSample?,
                                      containerWidth: Double,
                                      containerHeight: Double,
                                      heightIsContent: Bool = false) -> FoldDivision? {
        guard containerWidth.isFinite, containerWidth > 0 else { return nil }
        if let hinge {
            switch hinge.status {
            case .closed, .fullyOpen:
                return nil
            case .partiallyOpen, .unknown:
                break
            }
        }
        return divisions
            .filter { validFold($0, containerWidth: containerWidth,
                                containerHeight: containerHeight, heightIsContent: heightIsContent) }
            .max { lhs, rhs in
                if lhs.height != rhs.height { return lhs.height < rhs.height }
                return lhs.width < rhs.width
            }
    }

    public static func decide(_ input: Input, for screen: Screen) -> Decision {
        let width = finite(input.containerWidth)
        let height = finite(input.containerHeight)
        guard isWide(input) else {
            return Decision(mode: .phone, sideInset: 0, readableWidth: width, columns: 1, gutter: 0)
        }
        let readable = min(width, readableMaxWidth(screen))
        let inset = max(0, (width - readable) / 2)
        let inner = max(0, readable - screenGutter(screen) * 2)
        let columns = input.accessibilityTextSize ? 1 : columnCount(inner: inner, minColumn: minColumnWidth(screen))
        let ordinary = Decision(mode: .wide, sideInset: inset, readableWidth: readable, columns: columns,
                                gutter: columns > 1 ? columnGutter : 0)
        // TODO(#465 item 4): with `.twoPane`, Stations shows the grid beside the detail.
        guard let fold = input.foldDivision,
              validFold(fold, containerWidth: width, containerHeight: height, heightIsContent: input.heightIsContent) else {
            return ordinary
        }
        return foldAwareDecision(ordinary: ordinary, input: input, screen: screen, width: width, fold: fold)
    }

    private static func validFold(_ division: FoldDivision, containerWidth: Double,
                                  containerHeight: Double, heightIsContent: Bool) -> Bool {
        guard division.isActive, division.isVertical,
              division.minX.isFinite, division.minY.isFinite,
              division.width.isFinite, division.height.isFinite,
              division.width > 0, division.height > 0 else { return false }
        let foldMin = min(max(division.minX, 0), containerWidth)
        let foldMax = min(max(division.maxX, foldMin), containerWidth)
        guard foldMax > foldMin, foldMin > 0, foldMax < containerWidth else { return false }
        if !heightIsContent {
            guard containerHeight > 0,
                  division.height >= containerHeight * 0.5,
                  division.maxY > 0, division.minY < containerHeight else { return false }
        }
        return true
    }

    /// #465 item 2: keep every column and single-column reading band out of an active vertical fold.
    private static func foldAwareDecision(ordinary: Decision, input: Input, screen: Screen,
                                          width: Double, fold: FoldDivision) -> Decision {
        let foldMin = min(max(fold.minX, 0), width)
        let foldMax = min(max(fold.maxX, foldMin), width)
        let contentStart = ordinary.leadingInset
        let contentEnd = width - ordinary.trailingInset
        // If the centred content band already clears the fold, leave it untouched.
        guard contentStart < foldMax && contentEnd > foldMin else { return ordinary }

        let screenPad = screenGutter(screen)
        let maxReadable = readableMaxWidth(screen)
        let minCol = minColumnWidth(screen)

        // Multi-column screens: place 2 equal columns (one per side of the fold) with the gutter
        // covering the fold band.
        if !input.accessibilityTextSize, minCol.isFinite {
            let foldWidth = foldMax - foldMin
            let gutter = max(columnGutter, foldWidth)
            let extra = (gutter - foldWidth) / 2
            let gapStart = max(0, foldMin - extra)
            let gapEnd = min(width, gapStart + gutter)
            let actualGutter = gapEnd - gapStart
            let maxHalf = (maxReadable - actualGutter) / 2
            let side = min(min(gapStart, width - gapEnd), maxHalf)
            let colWidth = side - screenPad
            if colWidth >= minCol, colWidth >= StudioLayoutMetrics.touchTargetMin {
                let leading = max(0, gapStart - side)
                let trailing = max(0, (width - gapEnd) - side)
                let readable = max(0, width - leading - trailing)
                return Decision(mode: .wide, leadingInset: leading, trailingInset: trailing,
                                readableWidth: readable, columns: 2, gutter: actualGutter)
            }
        }

        // Single-column screens (or when the narrower side can't fit a column): move the column
        // to the wider side of the fold (leading on a tie, matching `FoldAwareness.bookColumn`).
        let leadingSpan = foldMin
        let trailingSpan = width - foldMax
        let useTrailing = trailingSpan > leadingSpan
        let chosenSpan = useTrailing ? trailingSpan : leadingSpan
        guard chosenSpan >= FoldAwareness.bookColumnMinSideWidth else { return ordinary }
        let readable = min(chosenSpan, maxReadable)
        let pad = max(0, (chosenSpan - readable) / 2)
        let leading = useTrailing ? (foldMax + pad) : pad
        let trailing = max(0, width - leading - readable)
        return Decision(mode: .wide, leadingInset: leading, trailingInset: trailing,
                        readableWidth: readable, columns: 1, gutter: 0)
    }

    static func columnCount(inner: Double, minColumn: Double) -> Int {
        guard minColumn.isFinite, minColumn > 0 else { return 1 }
        let fit = Int(((inner + columnGutter) / (minColumn + columnGutter)).rounded(.down))
        return max(1, min(maxColumns, fit))
    }

    /// The Duo's inner display, as `StudioCapture.duoWideContainerSize` and the
    /// `duoWideReady` capture stand it in. Compact class.
    public static let duoWide = Input(hasRegularWidth: false, containerWidth: 640, containerHeight: 820)
    /// Narrow Split View, compact class. The same window as #501's `SplitViewLayout.narrow`
    /// (340 × 760); adopt that sample when #501 lands rather than keeping two.
    public static let splitNarrow = Input(hasRegularWidth: false, containerWidth: 340, containerHeight: 760)

    private static func finite(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}
