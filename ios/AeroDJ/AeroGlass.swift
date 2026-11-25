import AeroDJCore
import SwiftUI

// One Liquid Glass treatment for bars, cards and buttons. Every glass surface in the app goes
// through `aeroGlass`, `aeroGlassControl` or `aeroConcentricGlass`, so iOS 26 glass, the pre-26
// look and the accessibility settings are decided in one place: `GlassTreatment` in
// AeroDJCore (#465 item 9), unit tested for every combination.
//
// - iOS 26 (built with the iOS 26 SDK): `glassEffect` in the surface's own shape. Controls get
//   `.interactive()` glass, so a press reacts the way system buttons do. Only play is
//   prominent and tinted; every other control is plain glass.
// - Before iOS 26, or an older SDK: the call site's existing fill (a material or the folded
//   white 8 % wash) plus its hairline, i.e. exactly what each surface drew before.
// - Reduce Transparency: an opaque fill plus the hairline. Dark in the dark folded UI.
// - Increase Contrast: the same opaque fill with a stronger edge.
// - Reduce Motion: glass stays, but nothing is interactive (no press morph or bounce).
//
// Content is never glass: this goes on chrome (the folded toolbar, chips, status capsules,
// the on-air card, the transport) and nothing changes size or position.

/// Debug-only overrides, so UI tests and captures can force the settings the simulator cannot
/// set from a launch argument (`-AeroDJReduceTransparency YES`, `-AeroDJIncreaseContrast YES`).
/// Reduce Motion reuses `StudioCapture.reduceMotionKey`. Release builds read only the system.
#if DEBUG
enum AeroGlassDebug {
    static let reduceTransparencyKey = "AeroDJReduceTransparency"
    static let increaseContrastKey = "AeroDJIncreaseContrast"
}
#endif

extension GlassAccessibility {
    /// The settings from SwiftUI's environment, plus the Debug overrides.
    static func resolve(reduceTransparency: Bool, contrast: ColorSchemeContrast,
                        reduceMotion: Bool) -> GlassAccessibility {
        #if DEBUG
        let defaults = UserDefaults.standard
        return GlassAccessibility(
            reduceTransparency: reduceTransparency || defaults.bool(forKey: AeroGlassDebug.reduceTransparencyKey),
            increaseContrast: contrast == .increased || defaults.bool(forKey: AeroGlassDebug.increaseContrastKey),
            reduceMotion: reduceMotion || defaults.bool(forKey: StudioCapture.reduceMotionKey))
        #else
        return GlassAccessibility(reduceTransparency: reduceTransparency,
                                  increaseContrast: contrast == .increased,
                                  reduceMotion: reduceMotion)
        #endif
    }

    /// True when this build has the iOS 26 SDK and runs on iOS 26 or later.
    static var glassAvailable: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

/// The edge drawn with the fallback, Reduce Transparency and Increase Contrast.
struct GlassEdge<S: Shape>: View {
    let shape: S
    let hairline: GlassHairline
    /// The call site's own hairline colour, used for `.standard`.
    let standard: Color?

    var body: some View {
        switch hairline {
        case .none:
            EmptyView()
        case .standard:
            if let standard {
                shape.stroke(standard, lineWidth: CGFloat(hairline.lineWidth))
            }
        case .strong:
            shape.stroke(Color.primary.opacity(hairline.opacity), lineWidth: CGFloat(hairline.lineWidth))
        }
    }
}

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
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var treatment: GlassTreatment {
        let a = GlassAccessibility.resolve(reduceTransparency: reduceTransparency, contrast: contrast,
                                           reduceMotion: reduceMotion)
        let available = GlassAccessibility.glassAvailable
        return role == .control
            ? .control(.secondary, accessibility: a, glassAvailable: available)
            : .surface(accessibility: a, glassAvailable: available)
    }

    func body(content: Content) -> some View {
        let t = treatment
        switch t.fill {
        case .solid:
            content
                .background(opaqueFill, in: shape)
                .overlay { edge(t.hairline) }
        case .glass, .glassProminent:
            glass(content, interactive: t.isInteractive)
        case .legacy:
            legacy(content)
        }
    }

    @ViewBuilder
    private func glass(_ content: Content, interactive: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular.interactive(interactive), in: shape)
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

    /// `.standard` keeps the exact pre-#465 inset 1 pt hairline; `.strong` is the contrast edge.
    @ViewBuilder
    private func edge(_ hairline: GlassHairline) -> some View {
        switch hairline {
        case .none: EmptyView()
        case .standard: hairlineStroke
        case .strong:
            shape.strokeBorder(Color.primary.opacity(hairline.opacity), lineWidth: CGFloat(hairline.lineWidth))
        }
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

// MARK: - Controls (#465 item 9)

/// A circular control's glass. Play is `.primary`: prominent glass tinted `tint`, the only
/// tinted control in the app. Every other control is `.secondary`: plain glass. The label
/// supplies only its glyph and frame, so the hit target and row geometry stay exactly as
/// they were.
///
/// iOS 26 draws `Glass.regular` (tinted for play) with `glassEffect` in a circle: the same
/// material as the system `.glass` / `.glassProminent` button styles, without those styles'
/// content insets, which would grow the 52 pt and 68 pt targets and move the iPhone row.
struct AeroGlassControl: ViewModifier {
    let emphasis: GlassEmphasis
    /// Play's tint. Also its fill before iOS 26 and when solid (the disc it always had).
    var tint: Color? = nil
    /// Opaque fill for other controls with Reduce Transparency or Increase Contrast.
    var solidFill: Color = Color(.secondarySystemBackground)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var treatment: GlassTreatment {
        .control(emphasis,
                 accessibility: GlassAccessibility.resolve(reduceTransparency: reduceTransparency,
                                                           contrast: contrast, reduceMotion: reduceMotion),
                 glassAvailable: GlassAccessibility.glassAvailable)
    }

    func body(content: Content) -> some View {
        let t = treatment
        switch t.fill {
        case .legacy:
            legacy(content, t)
        case .solid:
            content
                .background(Circle().fill(t.isTinted ? (tint ?? solidFill) : solidFill))
                .overlay {
                    // Play keeps its plain disc with Reduce Transparency; other solid circles get
                    // the app's 1 pt hairline. Increase Contrast gives both the strong edge.
                    GlassEdge(shape: Circle(), hairline: t.hairline,
                              standard: t.isTinted ? nil : Color.primary.opacity(GlassHairline.standard.opacity))
                }
        case .glass, .glassProminent:
            glass(content, t)
        }
    }

    /// Before iOS 26: play keeps its filled disc; other controls stay bare glyphs.
    @ViewBuilder
    private func legacy(_ content: Content, _ t: GlassTreatment) -> some View {
        if t.isTinted, let tint {
            content.background(Circle().fill(tint))
        } else {
            content
        }
    }

    @ViewBuilder
    private func glass(_ content: Content, _ t: GlassTreatment) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(Self.material(t, tint: tint), in: Circle())
        } else {
            legacy(content, t)
        }
        #else
        legacy(content, t)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private static func material(_ t: GlassTreatment, tint: Color?) -> Glass {
        let base = t.isTinted ? Glass.regular.tint(tint) : Glass.regular
        return base.interactive(t.isInteractive)
    }
    #endif
}

// MARK: - Concentric surfaces (#465 item 9)

/// A glass surface whose corners are concentric with its container on iOS 26
/// (`ConcentricRectangle`, uniform), and never tighter than `minimumRadius`, the radius the
/// surface always had. Before iOS 26: that fixed rounded rectangle and the call site's fill,
/// unchanged.
struct AeroConcentricGlass: ViewModifier {
    var minimumRadius: CGFloat
    /// The pre-iOS 26 fill.
    var fallback: AnyShapeStyle
    /// Reduce Transparency and Increase Contrast fill.
    var opaqueFill: Color = Color(.secondarySystemBackground)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var treatment: GlassTreatment {
        .surface(accessibility: GlassAccessibility.resolve(reduceTransparency: reduceTransparency,
                                                           contrast: contrast, reduceMotion: reduceMotion),
                 glassAvailable: GlassAccessibility.glassAvailable)
    }

    private var fixed: RoundedRectangle {
        RoundedRectangle(cornerRadius: minimumRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        let t = treatment
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(minimumRadius)), isUniform: true)
            if t.fill == .solid {
                content
                    .background(opaqueFill, in: shape)
                    .overlay { GlassEdge(shape: shape, hairline: t.hairline, standard: nil) }
            } else {
                content.glassEffect(Glass.regular, in: shape)
            }
        } else {
            legacy(content, t)
        }
        #else
        legacy(content, t)
        #endif
    }

    @ViewBuilder
    private func legacy(_ content: Content, _ t: GlassTreatment) -> some View {
        if t.fill == .solid {
            content
                .background(opaqueFill, in: fixed)
                .overlay { GlassEdge(shape: fixed, hairline: t.hairline, standard: nil) }
        } else {
            content.background(fallback, in: fixed)
        }
    }
}

extension View {
    /// A circular control's glass. See `AeroGlassControl`. Only play passes `.primary`.
    func aeroGlassControl(_ emphasis: GlassEmphasis, tint: Color? = nil,
                          solidFill: Color = Color(.secondarySystemBackground)) -> some View {
        modifier(AeroGlassControl(emphasis: emphasis, tint: tint, solidFill: solidFill))
    }

    /// A glass surface with concentric corners. See `AeroConcentricGlass`.
    func aeroConcentricGlass(minimumRadius: CGFloat, fallback: AnyShapeStyle,
                             opaqueFill: Color = Color(.secondarySystemBackground)) -> some View {
        modifier(AeroConcentricGlass(minimumRadius: minimumRadius, fallback: fallback, opaqueFill: opaqueFill))
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
                // #465 item 9: play is the only tinted control; Tune and Skip are plain glass.
                TransportRow(transport: .playing, actions: .preview, onTune: {})
                    .environment(\.onSlab, true)
                    .padding(.horizontal, 16)
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
