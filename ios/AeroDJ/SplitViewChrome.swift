import AeroDJCore
import SwiftUI

/// The safe area a split window measured, before SwiftUI has already applied any of it.
/// The capture sets this. A real window leaves it nil and the reader uses the view's insets.
struct SplitMeasure: Equatable {
    var containerWidth: Double
    var containerHeight: Double
    var leading: Double
    var trailing: Double
}

private struct SplitMeasureKey: EnvironmentKey {
    static let defaultValue: SplitMeasure? = nil
}

private struct SplitBarEdgeKey: EnvironmentKey {
    static let defaultValue: SplitViewLayout.BarEdge? = nil
}

extension EnvironmentValues {
    var splitMeasure: SplitMeasure? {
        get { self[SplitMeasureKey.self] }
        set { self[SplitMeasureKey.self] = newValue }
    }

    /// Nil on a full-screen iPhone. A split sets the outer edge.
    var splitBarEdge: SplitViewLayout.BarEdge? {
        get { self[SplitBarEdgeKey.self] }
        set { self[SplitBarEdgeKey.self] = newValue }
    }
}

/// What `SplitBarHost` resolved. Nil means the screen keeps today's placement.
struct SplitInsets: Equatable {
    var measuredLeading: Double
    var measuredTrailing: Double
    var appliedLeading: Double
    var appliedTrailing: Double
    var barEdge: SplitViewLayout.BarEdge
    var span: SplitViewLayout.Span

    var padding: SplitViewLayout.SidePadding {
        SplitViewLayout.sidePadding(measuredLeading: measuredLeading, measuredTrailing: measuredTrailing,
                                    appliedLeading: appliedLeading, appliedTrailing: appliedTrailing,
                                    designInset: 0)
    }
}

/// Reads the width class, the container and the two horizontal insets, then pads by
/// whichever side SwiftUI has not already inset. The closure sees nil on a full-screen
/// iPhone, and that branch is the screen as it was.
struct SplitBarHost<Content: View>: View {
    var preferred: SplitViewLayout.BarEdge
    @ViewBuilder var content: (SplitInsets?) -> Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.splitMeasure) private var measure
    @State private var insets: SplitInsets?
    @State private var reading = SplitReading(width: 0, height: 0, leading: 0, trailing: 0)

    var body: some View {
        Group {
            if let insets {
                padded(content(insets), insets)
                    .overlay(alignment: .top) {
                        SplitDecisionMark(text: SplitViewLayout.Chrome(
                            span: insets.span, barEdge: insets.barEdge,
                            leading: insets.measuredLeading, trailing: insets.measuredTrailing,
                            adapts: true, contentWidth: 0).decisionText)
                            .padding(.top, 4)
                    }
            } else {
                content(nil)
            }
        }
        .background { reader }
    }

    @ViewBuilder
    private func padded(_ view: Content, _ insets: SplitInsets) -> some View {
        let pad = insets.padding
        if pad.asymmetric {
            // A toolbar lays out in the safe area. Padding alone leaves the bar
            // on the window edge; the inset keeps every control on its own side.
            view
                .modifier(SplitSideInset(edge: .leading, width: pad.leading))
                .modifier(SplitSideInset(edge: .trailing, width: pad.trailing))
        } else {
            view
        }
    }

    private var reader: some View {
        GeometryReader { geo in
            let next = SplitReading(width: geo.size.width, height: geo.size.height,
                                    leading: geo.safeAreaInsets.leading,
                                    trailing: geo.safeAreaInsets.trailing)
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear { publish(next) }
                .onChange(of: next) { _, next in publish(next) }
        }
        .onChange(of: measure) { _, _ in publish(reading) }
        .onChange(of: horizontalSizeClass) { _, _ in publish(reading) }
    }

    private func publish(_ reading: SplitReading) {
        self.reading = reading
        // A capture passes the window's insets in `measure` and is not already
        // inside them. Reading the safe area back after this host adds its own
        // inset would cancel that inset on the next pass.
        let appliedLeading = measure == nil ? Double(reading.leading) : 0
        let appliedTrailing = measure == nil ? Double(reading.trailing) : 0
        let lead = measure?.leading ?? appliedLeading
        let trail = measure?.trailing ?? appliedTrailing
        let width = measure?.containerWidth
            ?? (Double(reading.width) + appliedLeading + appliedTrailing)
        let height = measure?.containerHeight ?? Double(reading.height)
        let chrome = SplitViewLayout.chrome(hasRegularWidth: horizontalSizeClass == .regular,
                                            containerWidth: width, containerHeight: height,
                                            leadingInset: lead, trailingInset: trail,
                                            preferredBarEdge: preferred)
        let next: SplitInsets? = chrome.adapts ? SplitInsets(
            measuredLeading: lead, measuredTrailing: trail,
            appliedLeading: appliedLeading, appliedTrailing: appliedTrailing,
            barEdge: chrome.barEdge, span: chrome.span) : nil
        if next != insets { insets = next }
    }
}

/// One-point readout the UI test reads. It does not take taps.
private struct SplitDecisionMark: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("split.decision")
            .accessibilityLabel(text)
            .allowsHitTesting(false)
    }
}

enum SplitToolbar {
    /// `edge` nil uses `preferred`, and the placement for that side is the one the
    /// screen already had (confirmation, cancellation, or a bar edge).
    static func placement(preferred: SplitViewLayout.BarEdge, edge: SplitViewLayout.BarEdge?,
                          leading: ToolbarItemPlacement, trailing: ToolbarItemPlacement) -> ToolbarItemPlacement {
        switch edge ?? preferred {
        case .leading: leading
        case .trailing: trailing
        }
    }
}

private struct SplitReading: Equatable {
    var width: CGFloat
    var height: CGFloat
    var leading: CGFloat
    var trailing: CGFloat
}

/// One side of a split. A zero width adds nothing, so the other side is the only inset.
private struct SplitSideInset: ViewModifier {
    var edge: HorizontalEdge
    var width: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if width > 0.5 {
            content.safeAreaInset(edge: edge, spacing: 0) {
                Color.clear
                    .frame(width: CGFloat(width))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

/// 44 pt only while a split is adapting. The phone branch is the control unchanged.
struct SplitMinimumTarget: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.frame(minWidth: 44, minHeight: 44)
        } else {
            content
        }
    }
}

/// Moves a trailing column to the leading edge. Text inside the columns stays left to right.
struct SplitLeadingBar: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.environment(\.layoutDirection, .rightToLeft)
        } else {
            content
        }
    }
}

struct SplitColumnText: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.environment(\.layoutDirection, .leftToRight)
        } else {
            content
        }
    }
}
