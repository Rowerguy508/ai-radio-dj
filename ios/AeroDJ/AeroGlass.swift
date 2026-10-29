import SwiftUI

// One Liquid Glass treatment for bars, cards and buttons. Every glass surface in the app goes
// through `aeroGlass`, so iOS 26 glass, the pre-26 look and Reduce Transparency are decided in
// one place:
//
// - iOS 26 (built with the iOS 26 SDK): `glassEffect` in the surface's own shape. Controls get
//   `.interactive()` glass, so a press reacts the way system buttons do.
// - Before iOS 26, or an older SDK: the call site's existing fill (a material or the folded
//   white 8 % wash) plus its hairline, i.e. exactly what each surface drew before.
// - Reduce Transparency: an opaque fill plus the hairline. Dark in the dark folded UI.
//
// Content is never glass: this goes on chrome (the folded toolbar, chips, status capsules,
// the on-air card) and nothing changes size or position.

enum AeroGlassRole {
    /// Bars, cards and capsules that only display.
    case surface
    /// Buttons: interactive glass on iOS 26.
    case control
}

struct AeroGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var role: AeroGlassRole = .surface
    /// The pre-iOS 26 fill, unchanged from what the surface drew before.
    var fallback: AnyShapeStyle
    /// Drawn with the fallback and with Reduce Transparency. iOS 26 glass draws its own edge.
    var hairline: Color? = nil
    /// Reduce Transparency fill.
    var opaqueFill: Color = Color(.secondarySystemBackground)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(opaqueFill, in: shape)
                .overlay { hairlineStroke }
        } else {
            glass(content)
        }
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(role == .control ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background(fallback, in: shape)
            .overlay { hairlineStroke }
    }

    @ViewBuilder
    private var hairlineStroke: some View {
        if let hairline {
            shape.strokeBorder(hairline, lineWidth: 1)
        }
    }
}

extension View {
    /// The shared glass treatment. See `AeroGlass`.
    func aeroGlass<S: InsettableShape>(_ shape: S, role: AeroGlassRole = .surface,
                                       fallback: AnyShapeStyle, hairline: Color? = nil,
                                       opaqueFill: Color = Color(.secondarySystemBackground)) -> some View {
        modifier(AeroGlass(shape: shape, role: role, fallback: fallback, hairline: hairline, opaqueFill: opaqueFill))
    }
}

/// Groups neighbouring glass shapes (a toolbar row) so iOS 26 renders them as one family and
/// can blend them. Before iOS 26 it is just the content.
struct AeroGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

#if DEBUG
/// Every role and shape the app uses, on the near-black folded backdrop.
private struct AeroGlassGallery: View {
    var body: some View {
        ZStack {
            FoldedStyle.background.ignoresSafeArea()
            LinearGradient(colors: [.pink.opacity(0.5), .clear], startPoint: .topLeading, endPoint: .center)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Card")
                    .foregroundStyle(.white)
                    .frame(width: 220, height: 120)
                    .foldedGlass(RoundedRectangle(cornerRadius: FoldedStyle.artRadius, style: .continuous))
                Text("Preparing your break")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 32)
                    .foldedGlass(Capsule())
                AeroGlassGroup {
                    HStack(spacing: 8) {
                        Text("Playing from Morning Calm")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: FoldedStyle.toolbarHeight)
                            .foldedGlass(Capsule(), role: .control)
                        ForEach(["list.bullet", "slider.horizontal.3"], id: \.self) { symbol in
                            Image(systemName: symbol)
                                .foregroundStyle(.white)
                                .frame(width: FoldedStyle.toolbarHeight, height: FoldedStyle.toolbarHeight)
                                .foldedGlass(Circle(), role: .control)
                        }
                    }
                }
                .padding(.horizontal, 16)
                Text("Studio surface")
                    .frame(width: 220, height: 80)
                    .studioSurface()
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

#Preview("Glass roles") {
    AeroGlassGallery()
}

/// Reduce Transparency cannot be set from a preview environment; on a device or simulator,
/// Settings > Accessibility > Display & Text Size > Reduce Transparency shows the opaque fills.
#Preview("Glass roles, large text") {
    AeroGlassGallery()
        .dynamicTypeSize(.accessibility1)
}
#endif
