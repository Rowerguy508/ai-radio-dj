import SwiftUI
import UIKit

/// Appearance-aware colours for text and controls. Each one has Any, Dark, and
/// High Contrast variants, resolved from the trait collection. They live here
/// rather than in an asset catalog so the app does not gain an AppIcon requirement.
///
/// Generated station art is not one of these colours: its backing is darkened
/// until light type clears WCAG AA, because that art does not follow the system
/// appearance.
enum AeroDJPalette {
    /// Body and caption text. 4.5:1 on system backgrounds and on the station wash.
    static var secondaryText: Color { color(light: 0x4A4A50, dark: 0xD1D1D6, lightHC: 0x3C3C43, darkHC: 0xEBEBF5) }
    /// Captions on the translucent Connections card (#311). The light sheet is glass over the
    /// dark player, so the card can read as mid grey (~0xABABAC measured) where
    /// `secondaryText` is only ~3.8:1. This ink is >= 6:1 there and ~14:1 on white. Dark is unchanged.
    static var cardCaptionText: Color { color(light: 0x2C2C30, dark: 0xD1D1D6, lightHC: 0x1C1C1E, darkHC: 0xEBEBF5) }
    /// Connected / active. 4.5:1 on the card and on its own 12% wash.
    static var statusPositive: Color { color(light: 0x085C32, dark: 0x5FE08A, lightHC: 0x064E2A, darkHC: 0xA7F3D0) }
    /// Pending. 4.5:1 on the card and on its own 12% wash.
    static var statusPending: Color { color(light: 0x8A4B00, dark: 0xFFB340, lightHC: 0x6B3A00, darkHC: 0xFFE0B0) }
    /// Problem text. 4.5:1 on the card and on its own 12% wash.
    static var statusProblem: Color { color(light: 0xB42318, dark: 0xFF6961, lightHC: 0x8C1C14, darkHC: 0xFFC7C3) }
    /// Links and "applies next" captions that used to be `.tint`.
    static var accentText: Color { color(light: 0x0844A8, dark: 0x8ECAFF, lightHC: 0x003E99, darkHC: 0xE7F1FF) }
    /// On Air capsule. White type clears 4.5:1 on this fill in both appearances.
    static var onAirFill: Color { color(light: 0x9B1B1B, dark: 0x9B1B1B, lightHC: 0x6E1010, darkHC: 0x6E1010) }
    /// Selected tag chip. White type clears 4.5:1 on this fill in both appearances.
    static var chipSelectedFill: Color { color(light: 0x0A4FBF, dark: 0x0A4FBF, lightHC: 0x003E99, darkHC: 0x003E99) }
    /// Light type drawn on station art and on the fills above. Same value in Any and Dark.
    static var onMediaLight: Color { color(light: 0xFFFFFF, dark: 0xFFFFFF, lightHC: 0xFFFFFF, darkHC: 0xFFFFFF) }
    /// Dark type drawn on a light station colour. High Contrast is black.
    static var onMediaInk: Color { color(light: 0x1C1C1E, dark: 0x1C1C1E, lightHC: 0x000000, darkHC: 0x000000) }
    /// Opaque warm black under Now Playing. Dark mode darkens it. Artwork never uses this.
    static var slab: Color { color(light: 0x1C1714, dark: 0x0C0A09, lightHC: 0x000000, darkHC: 0x000000) }
    /// Secondary type on `slab`. 4.5:1 in both appearances. Primary type on the slab is `onMediaLight`.
    static var slabSecondary: Color { color(light: 0xE4D5C5, dark: 0xE4D5C5, lightHC: 0xFFFFFF, darkHC: 0xFFFFFF) }

    /// WCAG AA for text under 18 pt, and for 14 pt that is not bold.
    static let textMinimum: CGFloat = 4.5

    /// True when light type is the one that clears `minimum` on `background`.
    static func prefersLightText(on background: Color, minimum: CGFloat = textMinimum, scheme: ColorScheme) -> Bool {
        let bg = resolved(background, scheme: scheme)
        let lightRatio = ratio(UIColor.white, bg)
        let inkRatio = ratio(inkUIColor, bg)
        if lightRatio >= minimum, lightRatio >= inkRatio { return true }
        if inkRatio >= minimum { return false }
        return lightRatio >= inkRatio
    }

    /// The same colour, or a darker shade, so solid white type clears `minimum`.
    /// Returns `color` unchanged when it already clears, so a passing accent is not shifted.
    static func backing(forLightText color: Color, minimum: CGFloat = textMinimum) -> Color {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard rgba(resolved, &r, &g, &b, &a) else { return color }
        let light = UIColor.white
        var bg = UIColor(red: r, green: g, blue: b, alpha: 1)
        if ratio(light, bg) >= minimum { return color }
        var scale: CGFloat = 1
        var steps = 0
        while ratio(light, bg) < minimum, steps < 24 {
            scale *= 0.92
            bg = UIColor(red: r * scale, green: g * scale, blue: b * scale, alpha: 1)
            steps += 1
        }
        return Color(uiColor: bg)
    }

    private static let inkUIColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)

    private static func color(light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let night = traits.userInterfaceStyle == .dark
            let high = traits.accessibilityContrast == .high
            switch (night, high) {
            case (false, false): return ui(light)
            case (true, false): return ui(dark)
            case (false, true): return ui(lightHC)
            case (true, true): return ui(darkHC)
            }
        })
    }

    private static func ui(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func resolved(_ color: Color, scheme: ColorScheme) -> UIColor {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        return UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private static func rgba(_ color: UIColor, _ r: inout CGFloat, _ g: inout CGFloat, _ b: inout CGFloat, _ a: inout CGFloat) -> Bool {
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) { return true }
        guard let comps = color.cgColor.components, comps.count >= 3 else { return false }
        r = comps[0]
        g = comps[1]
        b = comps[2]
        a = comps.count > 3 ? comps[3] : 1
        return true
    }

    /// WCAG 2 relative luminance contrast.
    static func ratio(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let hi = max(luminance(a), luminance(b))
        let lo = min(luminance(a), luminance(b))
        return (hi + 0.05) / (lo + 0.05)
    }

    private static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard rgba(color, &r, &g, &b, &a) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.04045 ? v / 12.92 : CGFloat(pow(Double((v + 0.055) / 1.055), 2.4))
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}
