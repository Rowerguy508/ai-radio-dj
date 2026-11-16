import AeroDJCore
import SwiftUI

// The unfolded Duo's right rail (#465, mockup 02). Glass styling lives only in this file
// so it can move into Nova's shared glass helper later. No other control is restyled here.
//
// On iOS 27.1, built with that SDK, the same controls go in the system vertical toolbar.
// Xcode 26.6 / iphoneos 26.5 (CI) compiles only the custom rail below.

/// Actions the rail and, on iOS 27.1, the system vertical toolbar share.
struct DuoRailHooks {
    var dj: DJStatusPresentation
    var reviewCount: Int?
    var upNext: [TrackInfo]
    var onConnections: () -> Void
    var onQueue: () -> Void
    var onTune: () -> Void
    var onCollapse: () -> Void
    var pause: () -> Void
    var transport: TransportState = .stopped
    var startTimedOut: Bool = false
    var showsTransport: Bool = false
    var cancelStart: () -> Void = {}
    var resume: () async -> Void = {}
    var skip: () async -> Void = {}
}

extension View {
    /// No-op unless this binary is the iOS 27.1 SDK and the container is the unfolded Duo.
    /// `keepBehavior` stays set while the container is still that size, including after collapse,
    /// so the vertical-bar behavior is not toggled as view state.
    func duoSystemVerticalRail(_ hooks: DuoRailHooks?, keepBehavior: Bool) -> some View {
        modifier(DuoSystemRailAttacher(hooks: hooks, keepBehavior: keepBehavior))
    }
}

struct DuoVerticalRail: View {
    let dj: DJStatusPresentation
    let reviewCount: Int?
    let upNext: [TrackInfo]
    let onCollapse: () -> Void
    let onConnections: () -> Void
    let onQueue: () -> Void
    let onTune: () -> Void
    let pause: () -> Void
    var transport: TransportState = .stopped
    var startTimedOut: Bool = false
    var showsTransport: Bool = false
    var cancelStart: () -> Void = {}
    var resume: () async -> Void = {}
    var skip: () async -> Void = {}
    @Binding var moreOpen: Bool

    /// True only in a binary built with the iOS 27.1 SDK, running on iOS 27.1+.
    /// The 26.5 CI build always takes the custom rail.
    static var usesSystemBar: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) { return true }
        #endif
        return false
    }

    var body: some View {
        VStack(spacing: CGFloat(DuoRailLayout.spacing)) {
            DuoRailIconButton(systemImage: "chevron.down", label: "Collapse",
                              hint: "Shows the folded player. Music continues.",
                              identifier: "folded.collapse", action: onCollapse)
            DuoRailMoreButton(open: $moreOpen, reviewCount: reviewCount)
            if showsTransport {
                DuoRailPlayPauseButton(transport: transport, startTimedOut: startTimedOut,
                                       pause: pause, cancelStart: cancelStart, resume: resume)
                DuoRailIconButton(systemImage: "forward.fill", label: "Skip",
                                  hint: "Skips this song.",
                                  identifier: "transport.skip",
                                  action: { Task { await skip() } })
            }
            DuoRailIconButton(systemImage: "list.bullet", label: Self.queueLabel(upNext),
                              hint: "Opens the queue",
                              identifier: "queue.affordance", action: onQueue)
            DuoSleepTimerButton(pause: pause)
            Spacer(minLength: CGFloat(DuoRailLayout.spacerMinLength))
            DuoLiveDot(state: dj.state)
        }
        .padding(.vertical, CGFloat(DuoRailLayout.verticalPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Identifiers stay on the buttons. The glass modifier must not become the element.
        .accessibilityElement(children: .contain)
        .modifier(DuoRailGlass())
    }

    static func queueLabel(_ upNext: [TrackInfo]) -> String {
        upNext.first.map { "Up next: \($0.title) by \($0.artistName)" } ?? "Up next: nothing queued"
    }
}

// MARK: - Glass (local to this rail)

/// One glass column. Reduce Transparency and Increase Contrast use an opaque fill.
/// Nothing here animates, so Reduce Motion has no transition to remove.
private struct DuoRailGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)
        let strong = contrast == .increased
        if reduceTransparency || strong {
            content
                .background(FoldedStyle.opaqueGlass, in: shape)
                .overlay {
                    shape.strokeBorder(Color.white.opacity(strong ? 0.95 : 0.45),
                                       lineWidth: strong ? 2 : 1)
                }
        } else {
            glass(content, shape: shape)
        }
    }

    @ViewBuilder
    private func glass<S: InsettableShape>(_ content: Content, shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            filled(content, shape: shape)
        }
        #else
        filled(content, shape: shape)
        #endif
    }

    private func filled<S: InsettableShape>(_ content: Content, shape: S) -> some View {
        content
            .background(FoldedStyle.glassFill, in: shape)
            .overlay { shape.strokeBorder(FoldedStyle.hairline, lineWidth: 1) }
    }
}

// MARK: - Controls

private struct DuoRailIconButton: View {
    let systemImage: String
    let label: String
    let hint: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}


/// The same tap policy as `TransportRow`, sized to the rail's 44 pt plate so it fits
/// in `duoBarWidth`. Identifiers stay `transport.playPause` / `transport.skip`.
private struct DuoRailPlayPauseButton: View {
    let transport: TransportState
    let startTimedOut: Bool
    let pause: () -> Void
    let cancelStart: () -> Void
    let resume: () async -> Void

    private var face: TransportButtonFace {
        TransportTapPolicy.face(transport: transport, startTimedOut: startTimedOut)
    }

    var body: some View {
        Button {
            switch TransportTapPolicy.decide(transport: transport, startTimedOut: startTimedOut) {
            case .ignore:
                break
            case .cancelStart:
                cancelStart()
            case .pause:
                pause()
            case .play:
                Task { await resume() }
            }
        } label: {
            Group {
                if let systemImage = face.systemImage {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .accessibilityLabel(face.accessibilityLabel)
                }
            }
            .frame(width: CGFloat(DuoRailLayout.controlSize), height: CGFloat(DuoRailLayout.controlSize))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(face.accessibilityLabel)
        .accessibilityRemoveTraits(face.isActionable ? [] : .isButton)
        .accessibilityIdentifier("transport.playPause")
    }
}

/// ⋯ for the rail only. The navigation-bar menu is untouched.
struct DuoRailMoreButton: View {
    @Binding var open: Bool
    var reviewCount: Int? = nil

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reviewCount.map { $0 > 0 ? "More, \($0) to review" : "More" } ?? "More")
        .accessibilityIdentifier("folded.more")
    }
}

/// Inward of the rail, inside the safe box. The panel hugs its labels up to `width`
/// (the space that ends before the rail) so the title is not clipped at the trailing
/// edge, including at the largest Dynamic Type the UI tests launch. Rows stay 44 pt
/// and scroll when the stack is taller than the window. Not a system popover: that
/// one opened off the trailing edge.
struct DuoRailMorePanel: View {
    let reviewCount: Int?
    /// Widest the panel may be. The trailing edge stays put; extra room grows inward.
    let width: CGFloat
    let maxHeight: CGFloat
    let onConnections: () -> Void
    let onTune: () -> Void
    let dismiss: () -> Void

    var body: some View {
        RailMenuWidth(maxWidth: width) {
            ViewThatFits(in: .vertical) {
                horizontalFit
                ScrollView { horizontalFit }
                    .frame(maxHeight: maxHeight)
            }
        }
        .background(FoldedStyle.opaqueGlass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folded.moreMenu")
    }

    /// One line when the titles fit before the rail; otherwise wrap inside `width`.
    private var horizontalFit: some View {
        ViewThatFits(in: .horizontal) {
            menuRows.fixedSize(horizontal: true, vertical: true)
            menuRows.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var menuRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Connections", systemImage: "link", identifier: "more.connections", action: onConnections)
            if let reviewCount, reviewCount > 0 {
                row("Review \(reviewCount) shared \(reviewCount == 1 ? "item" : "items")",
                    systemImage: "exclamationmark.bubble", identifier: "more.review", action: onConnections)
            }
            row("Tune station", systemImage: "slider.horizontal.3", identifier: "transport.tune",
                hint: "Opens the tuner. Music continues.", action: onTune)
        }
        .padding(.vertical, 4)
    }

    private func row(_ title: String, systemImage: String, identifier: String, hint: String? = nil,
                     action: @escaping () -> Void) -> some View {
        // Contain keeps the button hittable and exposes the title as its own element.
        // The title's frame is the text, so a label clipped on the trailing edge fails
        // even when the 44 pt row is still inside the window.
        Button {
            dismiss()
            action()
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.body)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).label")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .modifier(RailHint(hint: hint))
    }
}

/// Proposes at most `maxWidth` and reports the child's size, so the menu hugs its
/// labels and still stops before the rail. A plain `frame(maxWidth:)` fills the
/// proposal instead of shrinking to the text.
private struct RailMenuWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return CGSize(width: 44, height: 44) }
        let limit = min(proposal.width ?? maxWidth, maxWidth)
        let size = child.sizeThatFits(ProposedViewSize(width: limit, height: proposal.height))
        return CGSize(width: min(max(size.width, 44), limit), height: max(size.height, 44))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct RailHint: ViewModifier {
    var hint: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let hint, !hint.isEmpty {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

/// Pauses with the existing pause action after the chosen duration. Off does not pause.
private struct DuoSleepTimerButton: View {
    let pause: () -> Void
    @State private var minutes: Int?
    @State private var token = UUID()

    var body: some View {
        Menu {
            Button("Off") { arm(nil) }
                .accessibilityIdentifier("folded.sleepTimer.off")
            ForEach(DuoSleepTimer.minuteChoices, id: \.self) { choice in
                Button("\(choice) minutes") { arm(choice) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("folded.sleepTimer.\(choice)")
            }
        } label: {
            Image(systemName: "timer")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityHint("Pauses playback after the time you choose. Music continues until then.")
        .accessibilityValue(DuoSleepTimer.accessibilityValue(minutes: minutes))
        .accessibilityIdentifier("folded.sleepTimer")
        .task(id: token) {
            guard let minutes else { return }
            let armed = token
            do { try await Task.sleep(for: .seconds(Double(minutes * 60))) } catch { return }
            guard !Task.isCancelled, token == armed else { return }
            pause()
            self.minutes = nil
        }
    }

    private func arm(_ minutes: Int?) {
        self.minutes = minutes
        token = UUID()
    }
}

/// Lit only from `DJStudioState.onAirLabel` (`.speaking`). Not a new on-air flag.
private struct DuoLiveDot: View {
    let state: DJStudioState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var lit: Bool { DuoPresentation.railLiveDotLit(state) }

    var body: some View {
        let strong = contrast == .increased
        // The visible mark stays the mockup's small dot. The 44 pt plate is the hit target,
        // so VoiceOver and the UI test measure the control, not the 12 pt mark.
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.01))
                .frame(width: 44, height: 44)
            Circle()
                .fill(lit ? Self.litColor : Color.white.opacity(strong ? 0.85 : 0.28))
                .frame(width: strong ? 14 : 12, height: strong ? 14 : 12)
                .overlay {
                    if strong { Circle().strokeBorder(Color.white, lineWidth: 1.5) }
                }
                .shadow(color: lit && !reduceTransparency && !strong ? Self.litColor.opacity(0.75) : .clear,
                        radius: 8)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DJ live dot")
        .accessibilityValue(state.onAirLabel ?? "Off")
        .accessibilityIdentifier("folded.liveDot")
    }

    /// Mockup 02's live dot.
    private static let litColor = Color(red: 1, green: 59 / 255, blue: 47 / 255)
}

// MARK: - iOS 27.1 system vertical bar

private struct DuoSystemRailAttacher: ViewModifier {
    var hooks: DuoRailHooks?
    var keepBehavior: Bool

    func body(content: Content) -> some View {
        attached(content)
    }

    @ViewBuilder
    private func attached(_ content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *), keepBehavior {
            content.modifier(DuoSystemVerticalToolbar(hooks: hooks))
        } else {
            content
        }
        #else
        // Compiled out of the Xcode 26.6 / iphoneos 26.5 build. The custom rail is the bar.
        let _ = (hooks?.dj.onAirBadge, keepBehavior)
        content
        #endif
    }
}

#if compiler(>=6.4)
/// iOS 27.1 toolbar item. The arrow sits on the trailing edge so the menu opens inward.
@available(iOS 27.1, *)
private struct DuoRailSystemMore: View {
    let reviewCount: Int?
    let onConnections: () -> Void
    let onTune: () -> Void
    @State private var open = false

    var body: some View {
        let menu = DuoMoreMenuLayout.resolve(safeWidth: 640, safeHeight: 820)
        DuoRailMoreButton(open: $open, reviewCount: reviewCount)
            .popover(isPresented: $open, arrowEdge: .trailing) {
                DuoRailMorePanel(reviewCount: reviewCount, width: CGFloat(menu.width),
                                 maxHeight: CGFloat(min(menu.maxHeight, 360)),
                                 onConnections: onConnections, onTune: onTune, dismiss: { open = false })
                    .presentationCompactAdaptation(.popover)
            }
    }
}

@available(iOS 27.1, *)
private struct DuoSystemVerticalToolbar: ViewModifier {
    var hooks: DuoRailHooks?

    func body(content: Content) -> some View {
        if let hooks {
            content
                .toolbarVerticalBehavior(.automatic)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        DuoRailIconButton(systemImage: "chevron.down", label: "Collapse",
                                          hint: "Shows the folded player. Music continues.",
                                          identifier: "folded.collapse", action: hooks.onCollapse)
                    }
                    .axisBehavior(.verticalPreferred)
                    ToolbarItem(placement: .primaryAction) {
                        DuoRailSystemMore(reviewCount: hooks.reviewCount,
                                          onConnections: hooks.onConnections, onTune: hooks.onTune)
                    }
                    .axisBehavior(.verticalPreferred)
                    if hooks.showsTransport {
                        ToolbarItem(placement: .primaryAction) {
                            DuoRailPlayPauseButton(transport: hooks.transport,
                                                   startTimedOut: hooks.startTimedOut,
                                                   pause: hooks.pause, cancelStart: hooks.cancelStart,
                                                   resume: hooks.resume)
                        }
                        .axisBehavior(.verticalPreferred)
                        ToolbarItem(placement: .primaryAction) {
                            DuoRailIconButton(systemImage: "forward.fill", label: "Skip",
                                              hint: "Skips this song.",
                                              identifier: "transport.skip",
                                              action: { Task { await hooks.skip() } })
                        }
                        .axisBehavior(.verticalPreferred)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        DuoRailIconButton(systemImage: "list.bullet",
                                          label: DuoVerticalRail.queueLabel(hooks.upNext),
                                          hint: "Opens the queue",
                                          identifier: "queue.affordance", action: hooks.onQueue)
                    }
                    .axisBehavior(.verticalPreferred)
                    ToolbarItem(placement: .primaryAction) {
                        DuoSleepTimerButton(pause: hooks.pause)
                    }
                    .axisBehavior(.verticalPreferred)
                    ToolbarItem(placement: .bottomBar) {
                        DuoLiveDot(state: hooks.dj.state)
                    }
                    .axisBehavior(.verticalPreferred)
                }
        } else {
            content.toolbarVerticalBehavior(.automatic)
        }
    }
}
#endif
