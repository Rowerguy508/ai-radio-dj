import Foundation

// #465 item 9: Liquid Glass and corners. The decision of which glass a control or surface gets
// lives here, free of SwiftUI, so every combination of the three accessibility settings is
// unit tested on Linux. `AeroGlass.swift` in the app reads the environment, calls `resolve`,
// and only draws what it is told.
//
// Rules (owner-approved mockups, docs/mockups/465):
// - Glass is for the control layer only. Content stays solid.
// - Only play is tinted (`.glassProminent`). Every other control is plain `.glass`.
// - Reduce Transparency or Increase Contrast: solid, opaque fills. Increase Contrast also gets
//   a stronger edge.
// - Reduce Motion: no interactive glass (no press morph or bounce) and no symbol replace.
// - Before iOS 26 (or an SDK without glass): each call site's existing look, unchanged.

/// The three accessibility settings that change glass. Read from SwiftUI's environment
/// (`accessibilityReduceTransparency`, `colorSchemeContrast == .increased`,
/// `accessibilityReduceMotion`).
public struct GlassAccessibility: Equatable, Hashable, Sendable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool
    public var reduceMotion: Bool

    public init(reduceTransparency: Bool = false, increaseContrast: Bool = false, reduceMotion: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
    }

    /// All eight combinations, for tests and previews.
    public static let allCombinations: [GlassAccessibility] = [false, true].flatMap { rt in
        [false, true].flatMap { ic in
            [false, true].map { rm in
                GlassAccessibility(reduceTransparency: rt, increaseContrast: ic, reduceMotion: rm)
            }
        }
    }

    /// Either setting that asks for an opaque fill instead of glass.
    public var wantsSolid: Bool { reduceTransparency || increaseContrast }
}

/// How much a control stands out. Only play is `.primary`.
public enum GlassEmphasis: Equatable, Sendable {
    /// Play/Pause: `.glassProminent`, tinted.
    case primary
    /// Every other control (Tune, Skip, chips, toolbar buttons): plain `.glass`, untinted.
    case secondary
}

/// What fills the shape.
public enum GlassFill: Equatable, Sendable {
    /// iOS 26 `.glass` / `Glass.regular`.
    case glass
    /// iOS 26 `.glassProminent` (play only).
    case glassProminent
    /// An opaque fill (Reduce Transparency or Increase Contrast).
    case solid
    /// Before iOS 26: the call site's existing material or fill, unchanged.
    case legacy
}

/// The edge drawn around the shape.
public enum GlassHairline: Equatable, Sendable {
    /// No extra edge (iOS 26 glass draws its own).
    case none
    /// The call site's existing hairline, if it has one.
    case standard
    /// Increase Contrast: a visible, higher-contrast edge.
    case strong

    /// Stroke width in points. `standard` is the 1 pt the app already uses.
    public var lineWidth: Double {
        switch self {
        case .none: 0
        case .standard: 1
        case .strong: 1.5
        }
    }

    /// Opacity of the primary colour used for the edge.
    public var opacity: Double {
        switch self {
        case .none: 0
        case .standard: 0.12
        case .strong: 0.6
        }
    }
}

/// The resolved treatment for one control or surface.
public struct GlassTreatment: Equatable, Sendable {
    public let fill: GlassFill
    /// True only for play. Tint applies in every mode (solid play is filled in its tint).
    public let isTinted: Bool
    /// iOS 26 interactive glass: a press morphs and bounces. Off with Reduce Motion.
    public let isInteractive: Bool
    public let hairline: GlassHairline
    /// Symbol and state changes may animate (symbol replace, glass morph). Off with Reduce Motion.
    public let animates: Bool

    public init(fill: GlassFill, isTinted: Bool, isInteractive: Bool, hairline: GlassHairline, animates: Bool) {
        self.fill = fill
        self.isTinted = isTinted
        self.isInteractive = isInteractive
        self.hairline = hairline
        self.animates = animates
    }

    /// A button. `glassAvailable` is `#available(iOS 26.0, *)` built with the iOS 26 SDK.
    public static func control(_ emphasis: GlassEmphasis, accessibility a: GlassAccessibility,
                               glassAvailable: Bool) -> GlassTreatment {
        let tinted = emphasis == .primary
        let fill: GlassFill
        if a.wantsSolid {
            fill = .solid
        } else if !glassAvailable {
            fill = .legacy
        } else {
            fill = tinted ? .glassProminent : .glass
        }
        return GlassTreatment(fill: fill, isTinted: tinted,
                              isInteractive: (fill == .glass || fill == .glassProminent) && !a.reduceMotion,
                              hairline: hairline(fill: fill, accessibility: a),
                              animates: !a.reduceMotion)
    }

    /// A bar, card or capsule that only displays. Never tinted, never interactive.
    public static func surface(accessibility a: GlassAccessibility, glassAvailable: Bool) -> GlassTreatment {
        let fill: GlassFill = a.wantsSolid ? .solid : (glassAvailable ? .glass : .legacy)
        return GlassTreatment(fill: fill, isTinted: false, isInteractive: false,
                              hairline: hairline(fill: fill, accessibility: a),
                              animates: !a.reduceMotion)
    }

    private static func hairline(fill: GlassFill, accessibility a: GlassAccessibility) -> GlassHairline {
        if a.increaseContrast { return .strong }
        switch fill {
        case .glass, .glassProminent: return .none
        case .solid, .legacy: return .standard
        }
    }
}
