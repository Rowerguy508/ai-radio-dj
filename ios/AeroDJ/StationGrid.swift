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
/// TODO(#465 item 4): showing this grid beside the detail still needs owner mockups first.
/// The unused arrangement seam on `decide` is gone; this PR does not change that UI.
/// TODO(#465 item 2): with a `foldDivision`, keep the column gap on the fold.
/// Same SceneStorage key as `StationCarousel`: a fold destroys the compact
/// carousel and this grid must restore the focused card before falling back
/// to the selected station (#492, #493).
struct StationGrid: View {
    let stations: [Station]
    let selectedID: Station.ID?
    let layout: AppWideLayout.Decision
    let onSelect: (Station.ID) -> Void

    @SceneStorage("aerodj.stations.scrollAnchor") private var storedFocus = ""

    private var focusBinding: Binding<Station.ID?> {
        Binding(
            get: { storedFocus.isEmpty ? nil : UUID(uuidString: storedFocus) },
            set: { storedFocus = $0?.uuidString ?? "" }
        )
    }

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
                // The id sits on the grid, not the scroll view: in the wide capture the
                // column's scroll view is exposed as `split.sidebar`, which drops an id here.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("stations.grid")
                // Same as the carousel: without this, `scrollPosition` never
                // writes `aerodj.stations.scrollAnchor` when the user scrolls.
                .scrollTargetLayout()
            }
            .scrollPosition(id: focusBinding)
            .scrollContentBackground(.hidden)
            .background(FoldedStyle.background.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                // A stored carousel/grid focus wins. The selected station is only
                // the default when nothing was scrolled, same as the carousel.
                let session = DisplayContinuity.Session(
                    selectedStationID: selectedID?.uuidString,
                    scrollAnchor: storedFocus.isEmpty ? nil : storedFocus,
                    playbackToken: "",
                    loadCount: 0
                ).appeared(defaultAnchor: selectedID?.uuidString)
                if let anchor = session.scrollAnchor, anchor != storedFocus {
                    storedFocus = anchor
                }
                if let id = UUID(uuidString: storedFocus) ?? selectedID {
                    reader.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: selectedID) { _, id in
                guard let id, id.uuidString != storedFocus else { return }
                storedFocus = id.uuidString
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
