import Foundation

/// Which column a collapsed (compact-width) station split shows.
public enum StationSplitColumn: Equatable, Sendable {
    /// The station picker: the carousel on a folded phone.
    case list
    /// The open station.
    case detail
}

/// The one source of truth for the station split: which station is selected and what each
/// width class shows for it. `StationSplitRoot` stores this and derives both
/// `preferredCompactColumn` (compact) and the detail column (regular) from it, so a width-class
/// change in either direction keeps the open station on screen.
///
/// Before this type the compact column was its own `@State`. A restore in regular width (open
/// Duo, Max phone in landscape, full-width iPad) set only the selection, and the width-class
/// change only reset column visibility, so folding, rotating to portrait or entering Split View
/// collapsed to the carousel while the station stayed selected and playing.
///
/// Pure value type: no SwiftUI, no device model. Unit tested on Linux.
public struct StationSplitNavigation<ID: Hashable & Sendable>: Equatable, Sendable {
    /// The open station. Width-class changes never write it.
    public private(set) var selectedID: ID?
    /// Whether the window currently has a regular width class. Nil (`unspecified`) is compact.
    public private(set) var isRegularWidth = false
    /// What compact width shows. Only a back gesture in compact width moves it to `.list`
    /// while a station is selected.
    private var compactColumnChoice: StationSplitColumn = .list
    /// Set once a stored id was applied or the listener picked a station. A later restore
    /// (the list arriving, the stored id changing) never overrides either.
    public private(set) var didApplyRestore = false

    /// Starts compact with nothing selected. The width class arrives through
    /// `setRegularWidth`, the same path the view's `onChange(initial:)` uses.
    public init() {}

    /// The column compact width shows: the open station whenever one is selected, unless the
    /// listener went back to the list in compact width.
    public var compactColumn: StationSplitColumn {
        selectedID == nil ? .list : compactColumnChoice
    }

    /// Regular width shows the sidebar and the detail side by side.
    public var showsBothColumns: Bool { isRegularWidth }

    /// Whether the open station is on screen in the current width class. Regular width shows
    /// the detail beside the list, and it keeps `compactColumn` at `.detail` whenever a station
    /// is selected (`setRegularWidth`, `compactColumnWritten`), so one rule covers both classes.
    public var isStationVisible: Bool { compactColumn == .detail }

    /// A tap on a row or carousel card: select and open, in either width class.
    public mutating func select(_ id: ID) {
        selectedID = id
        compactColumnChoice = .detail
        didApplyRestore = true
    }

    /// Copies a stored station id in once, when that station is in `available`. It opens the
    /// station for both width classes, whichever is current: the width class at launch must
    /// not decide what a later fold or rotation shows. Returns whether it applied.
    @discardableResult
    public mutating func restore(_ storedID: ID?, available: [ID]) -> Bool {
        guard !didApplyRestore, let storedID, available.contains(storedID) else { return false }
        didApplyRestore = true
        selectedID = storedID
        compactColumnChoice = .detail
        return true
    }

    /// The width class changed (fold or unfold, rotation, Split View or Slide Over). The
    /// selection is untouched. Entering regular width shows the selected station in the detail
    /// column, so the next collapse returns to that station rather than an older back gesture.
    public mutating func setRegularWidth(_ regular: Bool) {
        isRegularWidth = regular
        if regular, selectedID != nil { compactColumnChoice = .detail }
    }

    /// The split wrote `preferredCompactColumn`. In compact width that is the back gesture (or
    /// a push). In regular width both columns are visible and any write is the split's own
    /// bookkeeping, so it is ignored: it must not decide what the next collapse shows.
    public mutating func compactColumnWritten(_ column: StationSplitColumn) {
        guard !isRegularWidth else { return }
        compactColumnChoice = column
    }
}
