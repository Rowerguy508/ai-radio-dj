import AeroDJCore
import SwiftUI

// Morphing large-title header for a scrolling list (wireframe 01: "Stations" plus a 55 %
// subtitle). As the list scrolls, the large title moves with the content, shrinks toward its
// leading edge and fades; a compact inline bar then rises into the navigation bar. Every value
// comes from the scrolled distance through `HeaderMorph` (unit tested in AeroDJCore), so the
// morph tracks the finger and reverses exactly. Reduce Motion: a plain crossfade at halfway.
//
// UI only. It reads the scroll position and draws text; it adds no rows, no actions and no
// data, so the list's selection and identifiers are unchanged.

extension View {
    /// The morphing header on iOS 18+, where the scroll offset can be read from outside the
    /// list (`onScrollGeometryChange`). iOS 17 keeps the system large title, which already
    /// collapses on scroll.
    func morphingLargeTitle(_ title: String, subtitle: String? = nil) -> some View {
        modifier(MorphingLargeTitle(title: title, subtitle: subtitle))
    }
}

struct MorphingLargeTitle: ViewModifier {
    let title: String
    let subtitle: String?

    /// Points the content has moved up from rest. Negative while pulled down.
    @State private var scrolled: Double = 0
    /// The large header's own height: the top content margin and the collapse distance.
    @State private var headerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// System Reduce Motion, or the capture launch flag the UI tests use.
    private var reduceMotion: Bool {
        #if DEBUG
        systemReduceMotion || UserDefaults.standard.bool(forKey: StudioCapture.reduceMotionKey)
        #else
        systemReduceMotion
        #endif
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            morphing(content)
        } else {
            content
        }
    }

    @available(iOS 18.0, *)
    private func morphing(_ content: Content) -> some View {
        let progress = HeaderMorph.progress(scrolled: scrolled, collapseDistance: Double(headerHeight))
        let morph = HeaderMorph.at(progress: progress, reduceMotion: reduceMotion)
        return content
            // The header is an overlay, so the list keeps its rows and selection. This margin
            // makes room for it; it never changes while scrolling, so there is no feedback loop.
            .contentMargins(.top, headerHeight, for: .scrollContent)
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, value in
                scrolled = value
            }
            .overlay(alignment: .top) {
                LargeTitleHeader(title: title, subtitle: subtitle, morph: morph,
                                 animatesCrossfade: reduceMotion)
                    // Moves with the content (scrolling, not animation), never below rest.
                    .offset(y: -CGFloat(max(0, scrolled)))
                    .background {
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { headerHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, height in headerHeight = height }
                        }
                    }
                    .allowsHitTesting(false)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    InlineTitleBar(title: title, morph: morph, animatesCrossfade: reduceMotion)
                }
            }
    }
}

/// The expanded state: large bold title and a secondary subtitle, leading aligned.
/// Scale and fade are visual only, so its layout height (the collapse distance) is constant.
struct LargeTitleHeader: View {
    let title: String
    let subtitle: String?
    let morph: HeaderMorph
    /// Reduce Motion: the step from shown to hidden plays as a short fade.
    var animatesCrossfade = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(morph.largeScale, anchor: .bottomLeading)
        .opacity(morph.largeOpacity)
        .animation(animatesCrossfade ? .easeInOut(duration: 0.2) : nil, value: morph.largeOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHidden(morph.largeOpacity == 0)
        .accessibilityIdentifier("header.large")
    }
}

/// The collapsed state: the same title, compact, in the navigation bar's principal slot.
struct InlineTitleBar: View {
    let title: String
    let morph: HeaderMorph
    var animatesCrossfade = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .opacity(morph.inlineOpacity)
        .offset(y: morph.inlineYOffset)
        .animation(animatesCrossfade ? .easeInOut(duration: 0.2) : nil, value: morph.inlineOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHidden(morph.inlineOpacity == 0)
        .accessibilityIdentifier("header.inline")
    }
}

#if DEBUG
#Preview("Morphing header, live scroll") {
    NavigationStack {
        List(0..<30, id: \.self) { i in
            Text("Row \(i)")
        }
        .navigationTitle("AeroDJ")
        .morphingLargeTitle("Stations", subtitle: "Your AI-hosted radio, on Apple Music")
    }
}

#Preview("Morph states") {
    VStack(alignment: .leading, spacing: 24) {
        ForEach([0.0, 0.4, 0.7, 1.0], id: \.self) { p in
            let morph = HeaderMorph.at(progress: p, reduceMotion: false)
            VStack(alignment: .leading, spacing: 8) {
                Text("progress \(p, specifier: "%.1f")").font(.caption.monospaced()).foregroundStyle(.secondary)
                InlineTitleBar(title: "Stations", morph: morph)
                    .frame(maxWidth: .infinity)
                LargeTitleHeader(title: "Stations", subtitle: "Your AI-hosted radio, on Apple Music", morph: morph)
            }
        }
    }
    .padding(.vertical)
}

#Preview("Morph states, Reduce Motion") {
    VStack(alignment: .leading, spacing: 24) {
        ForEach([0.0, 0.49, 0.5, 1.0], id: \.self) { p in
            let morph = HeaderMorph.at(progress: p, reduceMotion: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("progress \(p, specifier: "%.2f")").font(.caption.monospaced()).foregroundStyle(.secondary)
                InlineTitleBar(title: "Stations", morph: morph)
                    .frame(maxWidth: .infinity)
                LargeTitleHeader(title: "Stations", subtitle: "Your AI-hosted radio, on Apple Music", morph: morph)
            }
        }
    }
    .padding(.vertical)
}
#endif
