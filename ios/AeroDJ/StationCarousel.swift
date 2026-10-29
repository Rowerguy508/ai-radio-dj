import AeroDJCore
import SwiftUI

// Stations picker on compact width (wireframe 01): station cards on a
// curved arc. UI only. Scrolling moves focus and nothing else; a tap on a card is the
// existing selection (`StationSplitRoot.selection`), which opens the station and never
// starts playback. No station data is read or sent beyond the list it is given.

/// Horizontal arc of station cards. The centred card is full size; neighbours shrink, tilt
/// outward and drop (`StationCarouselArc`). Cards snap to the centre (`.viewAligned`) and a
/// selection haptic plays when the centred card changes. Reduce Motion lays the row flat.
/// Accessibility text sizes get a plain vertical stack of full-width cards instead.
struct StationCarousel: View {
    let stations: [Station]
    /// The split root's selection. Drawn as a ring on that card and the `.isSelected` trait.
    let selectedID: Station.ID?
    /// The existing selection path. Called only from a tap on a card.
    let onSelect: (Station.ID) -> Void

    /// The card nearest the centre. Focus only: changing it never selects.
    @State private var focusedID: Station.ID?
    @State private var containerWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// System Reduce Motion, or the capture launch flag the UI tests use.
    private var reduceMotion: Bool {
        #if DEBUG
        systemReduceMotion || UserDefaults.standard.bool(forKey: StudioCapture.reduceMotionKey)
        #else
        systemReduceMotion
        #endif
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // No section heading of its own: the split root's morphing "Stations" header is the
            // one heading on this screen (two read as a duplicate, and VoiceOver hit both).
            VStack(alignment: .leading, spacing: 12) {
                if typeSize.isAccessibilitySize {
                    stacked
                } else {
                    arc
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(FoldedStyle.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: Arc

    /// Card width from the container, never a device size: 70 % of the column, 200–300 pt.
    private var cardWidth: CGFloat {
        guard containerWidth > 0 else { return 260 }
        return min(300, max(200, containerWidth * 0.7))
    }

    /// Leading and trailing margin that lets the first and last card reach the centre.
    private var sideMargin: CGFloat {
        guard containerWidth > 0 else { return 16 }
        return max(16, (containerWidth - cardWidth) / 2)
    }

    private var arc: some View {
        // Captured by value: the transition closure is `@Sendable` and must not read `self`.
        let flat = reduceMotion
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(stations) { station in
                    StationCarouselCard(station: station, isSelected: station.id == selectedID,
                                        onSelect: onSelect)
                        .frame(width: cardWidth)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            let arc = StationCarouselArc.at(phase: phase.value, reduceMotion: flat)
                            return content
                                .scaleEffect(arc.scale)
                                .rotationEffect(.degrees(arc.rotationDegrees))
                                .offset(y: arc.yOffset)
                                .opacity(arc.opacity)
                        }
                        .id(station.id)
                }
            }
            .scrollTargetLayout()
            // Room for the dropped, tilted side cards so the scroll view does not clip them.
            .padding(.top, 8)
            .padding(.bottom, StationCarouselArc.edgeDrop + 16)
        }
        .contentMargins(.horizontal, sideMargin, for: .scrollContent)
        // Content margins reach every scroll view inside the modifier, so without this the
        // morphing header's top margin would be added again inside the arc.
        .contentMargins(.vertical, 0, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $focusedID)
        .scrollClipDisabled()
        // On the scroll view itself: the split root puts `split.sidebar` on the whole column.
        .accessibilityIdentifier("stations.carousel")
        // Only when focus moves between cards, not when it is first set on appear.
        .sensoryFeedback(.selection, trigger: focusedID) { old, new in old != nil && new != nil }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in containerWidth = width }
            }
        }
        .onAppear {
            // Open on the selected station (a restored one too), else the first. Focus only.
            if focusedID == nil { focusedID = selectedID ?? stations.first?.id }
        }
        .onChange(of: selectedID) { _, id in
            // A restored selection can arrive after the first render; bring it to the centre.
            guard let id, id != focusedID else { return }
            if flat {
                focusedID = id
            } else {
                withAnimation(.snappy) { focusedID = id }
            }
        }
    }

    // MARK: Accessibility sizes

    private var stacked: some View {
        VStack(spacing: 12) {
            ForEach(stations) { station in
                StationCarouselCard(station: station, isSelected: station.id == selectedID,
                                    onSelect: onSelect)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// One station: art block, name and vibe line on dark glass, with a white ring when selected.
/// Colour comes only from the generated station art.
struct StationCarouselCard: View {
    let station: Station
    let isSelected: Bool
    let onSelect: (Station.ID) -> Void

    private static let radius: CGFloat = 24
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    }

    private var ref: StationRef { StationRef(id: station.id.uuidString, name: station.name) }

    var body: some View {
        Button {
            onSelect(station.id)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                art
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let description = station.description, !description.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "mic")
                                .accessibilityHidden(true)
                            Text(description)
                                .lineLimit(2)
                        }
                        .font(.subheadline)
                        .foregroundStyle(FoldedStyle.secondaryInk)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foldedGlass(shape)
            .overlay {
                if isSelected {
                    shape.strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the station. Music starts only when you press Play.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("stations.card.\(station.id.uuidString)")
    }

    private var art: some View {
        // Square art, sized by the card's own width (no device size).
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    StationArtwork(style: .station(ref), size: max(1, min(geo.size.width, geo.size.height)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FoldedStyle.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        [station.name, station.description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

#if DEBUG
#Preview("Carousel, nothing selected") {
    NavigationStack {
        StationCarousel(stations: Station.defaultStations, selectedID: nil, onSelect: { _ in })
            .navigationTitle("AeroDJ")
    }
}

#Preview("Carousel, Late Night selected") {
    NavigationStack {
        StationCarousel(stations: Station.defaultStations + StationCarouselPreview.extra,
                        selectedID: Station.lateNightID, onSelect: { _ in })
            .navigationTitle("AeroDJ")
    }
}

#Preview("Carousel, accessibility text") {
    NavigationStack {
        StationCarousel(stations: Station.defaultStations, selectedID: Station.morningCalmID, onSelect: { _ in })
            .navigationTitle("AeroDJ")
    }
    .dynamicTypeSize(.accessibility2)
}

private enum StationCarouselPreview {
    static let extra: [Station] = [
        Station(id: UUID(uuidString: "9E4C3D32-6071-4C8D-AE1F-2A3B4C5D6E7F")!,
                name: "Sunday Paper", description: "Bright, chatty, a little nosy"),
        Station(id: UUID(uuidString: "AF5D4E43-7182-4D9E-BF20-3B4C5D6E7F80")!,
                name: "Deep Focus", description: "Says almost nothing"),
    ]
}
#endif
