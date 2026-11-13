import AeroDJCore
import SwiftUI

// #465 item 10 (-Nova): Library, Stations and Settings on wide containers. The decision is
// `AppWideLayout` (AeroDJCore, Linux tested). This file only measures the container and hands
// the result down. On the phone path the environment value is nil, so every screen keeps the
// exact view it had before.

private struct AppWideLayoutKey: EnvironmentKey {
    static let defaultValue: AppWideLayout.Decision? = nil
}

extension EnvironmentValues {
    /// Nil on the phone path (every iPhone, narrow Split View) and outside an `AppWideHost`.
    /// Set only when the container adapts, so `nil` always means "draw today's screen".
    var appWideLayout: AppWideLayout.Decision? {
        get { self[AppWideLayoutKey.self] }
        set { self[AppWideLayoutKey.self] = newValue }
    }
}

/// Measures the container a screen gets and sets `\.appWideLayout` for it.
///
/// The content is always the same view, never behind an `if`, so crossing the threshold (a
/// Split View resize, or unfolding the Duo with a sheet open) keeps the screen's state. Only
/// values change: an inset, a column count.
///
/// TODO(#465 item 2): on forward-merge of #510, attach `FoldDivisionProbe` here and pass the
/// active vertical division it reports as `AppWideLayout.Input.foldDivision` (the types are
/// the same once `FoldDivision` is a typealias for `FoldAwareness.Division`).
/// TODO(#465 item 4): read the `ArrangementView` arrangement here and pass it as
/// `AppWideLayout.Input.arrangement`.
/// When #501 lands, `SplitBarHost` owns the bar edge; this host owns widths and columns.
private struct AppWideHost: ViewModifier {
    let screen: AppWideLayout.Screen
    /// Settings: widen the Form's own horizontal margin, but only when the container is
    /// wider than the readable cap. The phone and an iPad sheet are untouched.
    let formMargins: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var size: CGSize = .zero

    private var decision: AppWideLayout.Decision? {
        let input = AppWideLayout.Input(hasRegularWidth: horizontalSizeClass == .regular,
                                        containerWidth: size.width, containerHeight: size.height,
                                        accessibilityTextSize: typeSize.isAccessibilitySize,
                                        // Onboarding is a content-sized sheet; see `hasRegularHeight`.
                                        hasRegularHeight: screen == .onboarding ? verticalSizeClass == .regular : nil)
        let decision = AppWideLayout.decide(input, for: screen)
        return decision.adapts ? decision : nil
    }

    /// Replaces the Form's default margin (20 pt) only when the content is capped.
    private var formMargin: CGFloat? {
        guard formMargins, let decision, decision.sideInset > 0 else { return nil }
        return CGFloat(AppWideLayout.screenGutter(screen) + decision.sideInset)
    }

    func body(content: Content) -> some View {
        margined(content)
            .environment(\.appWideLayout, decision)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
    }
}

private extension AppWideHost {
    /// The phone path, an iPad sheet and any container under the readable cap get `content`
    /// untouched (not even a nil margin), so their Form keeps the system inset exactly.
    /// Only a capped Form takes this branch. Crossing the cap rebuilds the Form; Settings
    /// holds no state beyond an open delete confirmation, which a resize closes anyway.
    @ViewBuilder
    func margined(_ content: Content) -> some View {
        if let formMargin {
            content.contentMargins(.horizontal, formMargin, for: .scrollContent)
        } else {
            content
        }
    }
}

extension View {
    /// The one entry point for item 10 screens. `formMargins` is for a `Form` screen whose
    /// rows should stay at the readable width (Settings).
    func appWideScreen(_ screen: AppWideLayout.Screen, formMargins: Bool = false) -> some View {
        modifier(AppWideHost(screen: screen, formMargins: formMargins))
    }
}

extension AppWideLayout.Decision {
    /// Grid columns that fill the readable width, with the decision's gutter.
    var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: CGFloat(gutter), alignment: .top), count: max(1, columns))
    }
}
