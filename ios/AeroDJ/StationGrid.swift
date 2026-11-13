import AeroDJCore
import SwiftUI

/// #465 item 10 (-Nova): Stations on the unfolded Duo's inner display (compact class,
/// 640 × 820 pt). A grid of the carousel's own cards at the readable width, so the whole
/// list is visible at once instead of one card at a time. Only `StationSplitRoot` builds it,
/// and only when `AppWideLayout` gives more than one column. Phones, narrow Split View and
/// accessibility text sizes keep `StationCarousel`.
///
/// A tap is the split root's existing selection (`onSelect`), the same path as a carousel
/// card: it opens that station and starts it (#454). Nothing else selects.
///
/// TODO(#465 item 4): with `arrangement == .twoPane`, show this grid beside the detail.
/// TODO(#465 item 2): with a `foldDivision`, keep the column gap on the fold.
/// On forward-merge of #493, scroll to its stored `aerodj.stations.scrollAnchor` before the
/// selected station, like the carousel.
struct StationGrid: View {
    let stations: [Station]
    let selectedID: Station.ID?
    let layout: AppWideLayout.Decision
    let onSelect: (Station.ID) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVGrid(columns: layout.gridColumns, alignment: .leading, spacing: CGFloat(layout.gutter)) {
                    ForEach(stations) { station in
                        StationCarouselCard(station: station, isSelected: station.id == selectedID,
                                            onSelect: onSelect)
                            .frame(minHeight: StudioLayoutMetrics.touchTargetMin)
                            .id(station.id)
                    }
                }
                .padding(.horizontal, CGFloat(AppWideLayout.screenGutter(.stations) + layout.sideInset))
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background(FoldedStyle.background.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .accessibilityIdentifier("stations.grid")
            .onAppear {
                // A restored or carried-over selection is brought into view; no animation,
                // so Reduce Motion needs no branch. Scrolling never selects.
                if let selectedID { reader.scrollTo(selectedID, anchor: .center) }
            }
        }
    }
}

#if DEBUG
#Preview("Station grid, Duo inner display") {
    NavigationStack {
        StationGrid(stations: Station.defaultStations, selectedID: Station.lateNightID,
                    layout: AppWideLayout.decide(AppWideLayout.duoWide, for: .stations), onSelect: { _ in })
            .navigationTitle(AppName.display)
    }
    .frame(width: 640, height: 820)
}
#endif
