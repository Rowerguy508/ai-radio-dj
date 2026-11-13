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
    /// The screens item 10 covers. Onboarding is listed so its follow-up has a slot.
    public enum Screen: String, CaseIterable, Equatable, Sendable {
        case library
        case stations
        case settings
        case onboarding
    }

    /// TODO(#465 item 2): one `reservedRegions(kind: .division)` region in the container's
    /// points. Carried, never read: until item 2 lands every screen ignores it, and nil (the
    /// default) is today's behaviour on every device.
    ///
    /// The fields and init match `FoldAwareness.Division` in Fry's #510 one for one, so the
    /// forward-merge replaces this struct with one line,
    /// `public typealias FoldDivision = FoldAwareness.Division`, and the host passes the
    /// division `FoldDivisionProbe` reports. No conversion, and no second copy of the type.
    public struct FoldDivision: Equatable, Sendable {
        public var minX: Double
        public var minY: Double
        public var width: Double
        public var height: Double
        public var isActive: Bool

        public init(minX: Double, minY: Double, width: Double, height: Double, isActive: Bool) {
            self.minX = minX
            self.minY = minY
            self.width = width
            self.height = height
            self.isActive = isActive
        }

        public var maxX: Double { minX + width }
        public var maxY: Double { minY + height }
        /// A book fold runs vertically (the same rule as #510).
        public var isVertical: Bool { height > width }
    }

    /// TODO(#465 item 4): what `ArrangementView` gives the screen. Generic on purpose: item 4
    /// has no PR yet, so this names only "one pane" or "two panes" and leaves the API to it.
    /// Carried, never read: until item 4 lands every screen ignores it, and nil (the default)
    /// is today's behaviour.
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
        /// TODO(#465 item 2): nil until fold awareness supplies it. Ignored today.
        public var foldDivision: FoldDivision?
        /// TODO(#465 item 4): nil until `ArrangementView` supplies it. Ignored today.
        public var arrangement: Arrangement?

        public init(hasRegularWidth: Bool, containerWidth: Double, containerHeight: Double,
                    accessibilityTextSize: Bool = false,
                    foldDivision: FoldDivision? = nil, arrangement: Arrangement? = nil) {
            self.hasRegularWidth = hasRegularWidth
            self.containerWidth = containerWidth
            self.containerHeight = containerHeight
            self.accessibilityTextSize = accessibilityTextSize
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
        /// Added to each side, on top of the screen's own gutter, so the content stays at
        /// `readableWidth`. Zero on the phone path.
        public var sideInset: Double
        /// The content's width after `sideInset` on both sides (the screen's own gutter
        /// is still inside it). The container width on the phone path.
        public var readableWidth: Double
        /// Columns the screen's list or grid uses. 1 on the phone path, so a caller that
        /// sees 1 keeps its single-column view.
        public var columns: Int
        public var gutter: Double

        public init(mode: Mode, sideInset: Double, readableWidth: Double, columns: Int, gutter: Double) {
            self.mode = mode
            self.sideInset = sideInset
            self.readableWidth = readableWidth
            self.columns = columns
            self.gutter = gutter
        }

        public var adapts: Bool { mode == .wide }

        /// Debug readout for captures and UI tests: "wide 2 40".
        public var decisionText: String {
            "\(mode.name) \(columns) \(Int(sideInset.rounded()))"
        }
    }

    /// Readable caps, including the screen's own gutter. Library and Settings are reading
    /// columns. Stations is a grid of cards, so it may use more of the width.
    public static func readableMaxWidth(_ screen: Screen) -> Double {
        switch screen {
        case .library: 560
        case .settings: 560
        case .onboarding: 520
        case .stations: 960
        }
    }

    /// The gutter each screen already draws (`AddStationWalkthroughView` pads 20; a Form's
    /// inset group is 20; the station grid uses 16). Columns are counted inside it.
    public static func screenGutter(_ screen: Screen) -> Double {
        switch screen {
        case .library, .settings, .onboarding: 20
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
        guard FoldedColumnLayout.isWide(containerWidth: width), height > 0 else { return false }
        // Compact and short is a phone on its side (at most 430 pt tall), or the
        // compact-to-regular probe. Regular width needs no height: iPad sheets are shorter.
        return input.hasRegularWidth || height >= FoldedColumnLayout.duoMinHeight
    }

    public static func decide(_ input: Input, for screen: Screen) -> Decision {
        let width = finite(input.containerWidth)
        guard isWide(input) else {
            return Decision(mode: .phone, sideInset: 0, readableWidth: width, columns: 1, gutter: 0)
        }
        let readable = min(width, readableMaxWidth(screen))
        let inset = max(0, (width - readable) / 2)
        let inner = max(0, readable - screenGutter(screen) * 2)
        let columns = input.accessibilityTextSize ? 1 : columnCount(inner: inner, minColumn: minColumnWidth(screen))
        // TODO(#465 item 2): with a `foldDivision`, keep the column gap on the fold.
        // TODO(#465 item 4): with `.twoPane`, Stations shows the grid beside the detail.
        return Decision(mode: .wide, sideInset: inset, readableWidth: readable, columns: columns,
                        gutter: columns > 1 ? columnGutter : 0)
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
