import SwiftUI
import UIKit

/// Appearance-aware colours for text and controls. Each asset has Any, Dark, and
/// High Contrast variants. Generated station art is not an asset: its backing is
/// darkened until light type clears WCAG AA, because that art does not follow
/// the system appearance.
enum AeroDJPalette {
    /// Body and caption text. 4.5:1 on system backgrounds and on the station wash.
    static let secondaryText = Color("SecondaryText")
    /// Connected / active. 4.5:1 on the card and on its own 12% wash.
    static let statusPositive = Color("StatusPositive")
    /// Pending. 4.5:1 on the card and on its own 12% wash.
    static let statusPending = Color("StatusPending")
    /// Problem text. 4.5:1 on the card and on its own 12% wash.
    static let statusProblem = Color("StatusProblem")
    /// Links and "applies next" captions that used to be `.tint`.
    static let accentText = Color("AccentText")
    /// On Air capsule. White type clears 4.5:1 on this fill in both appearances.
    static let onAirFill = Color("OnAirFill")
    /// Selected tag chip. White type clears 4.5:1 on this fill in both appearances.
    static let chipSelectedFill = Color("ChipSelectedFill")
    /// Light type drawn on station art and on the fills above. Same value in Any and Dark.
    static let onMediaLight = Color("OnMediaLight")
    /// Dark type drawn on a light station colour. High Contrast is black.
    static let onMediaInk = Color("OnMediaInk")

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
