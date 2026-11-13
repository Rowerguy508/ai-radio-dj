import AeroDJCore
import SwiftUI

// One Liquid Glass treatment for controls, shared with the unfolded Duo rail.
// Content and artwork do not use it. Only a play control passes `prominent`.
// iOS 26 draws `glassEffect` / `.glass` / `.glassProminent` in a `ConcentricRectangle`.
// Reduce Transparency and Increase Contrast use an opaque fill. Reduce Motion adds no animation.

private struct ControlGlassKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set on the unfolded Duo and on Studio. The phone folded layout leaves this false,
    /// so that reskin is unchanged.
    var controlGlass: Bool {
        get { self[ControlGlassKey.self] }
        set { self[ControlGlassKey.self] = newValue }
    }
}

enum ControlGlassOverrides {
    static var reduceTransparency: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: StudioCapture.reduceTransparencyKey)
        #else
        false
        #endif
    }

    static var increaseContrast: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: StudioCapture.increaseContrastKey)
        #else
        false
        #endif
    }

    static var reduceMotion: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: StudioCapture.reduceMotionKey)
        #else
        false
        #endif
    }
}

extension View {
    /// The rail and any other control plate. Corners are a `ConcentricRectangle` on iOS 26.
    func controlGlassRail() -> some View {
        modifier(ControlGlassRail())
    }

    /// `.glassProminent` when `prominent` (play only). Otherwise `.glass`.
    /// No-op when `\.controlGlass` is false, so the phone folded controls stay as they are.
    func controlGlassButton(prominent: Bool) -> some View {
        modifier(ControlGlassButtonChrome(prominent: prominent))
    }

    /// Groups neighbouring glass controls. No-op unless control glass is on and transparency is allowed.
    func controlGlassGroup() -> some View {
        modifier(ControlGlassGroup())
    }
}

private struct ControlGlassRail: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var decision: ControlGlassDecision {
        ControlGlassDecision.resolve(
            reduceTransparency: reduceTransparency || ControlGlassOverrides.reduceTransparency,
            increaseContrast: contrast == .increased || ControlGlassOverrides.increaseContrast)
    }

    private var motionOff: Bool {
        !ControlGlassDecision.allowsAddedMotion(reduceMotion: reduceMotion || ControlGlassOverrides.reduceMotion)
    }

    func body(content: Content) -> some View {
        styled(content)
            .transaction { if motionOff { $0.disablesAnimations = true } }
    }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: 25), isUniform: true)
            plate(content, shape: shape)
        } else {
            plate(content, shape: RoundedRectangle(cornerRadius: 25, style: .continuous))
        }
        #else
        plate(content, shape: RoundedRectangle(cornerRadius: 25, style: .continuous))
        #endif
    }

    @ViewBuilder
    private func plate<S: InsettableShape>(_ content: Content, shape: S) -> some View {
        switch decision {
        case .opaque(let strong):
            content
                .background(FoldedStyle.opaqueGlass, in: shape)
                .overlay {
                    shape.strokeBorder(Color.white.opacity(strong ? 0.95 : 0.45), lineWidth: strong ? 2 : 1)
                }
        case .glass:
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

private struct ControlGlassButtonChrome: ViewModifier {
    var prominent: Bool
    @Environment(\.controlGlass) private var controlGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var decision: ControlGlassDecision {
        ControlGlassDecision.resolve(
            reduceTransparency: reduceTransparency || ControlGlassOverrides.reduceTransparency,
            increaseContrast: contrast == .increased || ControlGlassOverrides.increaseContrast)
    }

    func body(content: Content) -> some View {
        if !controlGlass {
            content
        } else {
            chrome(content)
                .frame(minWidth: 44, minHeight: 44)
                .transaction { transaction in
                    if !ControlGlassDecision.allowsAddedMotion(
                        reduceMotion: reduceMotion || ControlGlassOverrides.reduceMotion) {
                        transaction.disablesAnimations = true
                    }
                }
        }
    }

    @ViewBuilder
    private func chrome(_ content: Content) -> some View {
        switch decision {
        case .opaque(let strong):
            content
                .background {
                    Circle().fill(prominent ? AeroDJPalette.onMediaLight : FoldedStyle.opaqueGlass)
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(strong ? 0.95 : 0.55), lineWidth: strong ? 2 : 1)
                }
        case .glass:
            glassButton(content)
        }
    }

    @ViewBuilder
    private func glassButton(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if ControlGlassDecision.isProminent(play: prominent) {
                content.buttonStyle(.glassProminent).tint(.white)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct ControlGlassGroup: ViewModifier {
    @Environment(\.controlGlass) private var controlGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var showsGlass: Bool {
        controlGlass && ControlGlassDecision.resolve(
            reduceTransparency: reduceTransparency || ControlGlassOverrides.reduceTransparency,
            increaseContrast: contrast == .increased || ControlGlassOverrides.increaseContrast) == .glass
    }

    func body(content: Content) -> some View {
        if !showsGlass {
            content
        } else {
            grouped(content)
        }
    }

    @ViewBuilder
    private func grouped(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
