/// Day-part tint behind the unfolded Duo's left art column (`FoldedPlayer.dayWash`).
///
/// Pure and UI-free so Linux can pin the RGB values and check contrast. The colours
/// are the ones `#462` shipped in `DuoDayWashFill`; this move does not change them.
/// Opacity, the top-to-bottom fade, and Reduce Transparency all stay in the view.
public enum DayWashPalette {
    /// sRGB component in 0...1, the same space `SwiftUI.Color(red:green:blue:)` uses.
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// Gradient endpoints for a day part. Both ends are the same tint today; the view
    /// still fades `top` at 0.9 opacity to `bottom` at 0.
    public static func colors(for part: DayPart) -> (top: RGB, bottom: RGB) {
        let tint: RGB
        switch part {
        case .earlyMorning: tint = RGB(red: 0.96, green: 0.78, blue: 0.62)
        case .morning: tint = RGB(red: 0.98, green: 0.86, blue: 0.55)
        case .afternoon: tint = RGB(red: 0.62, green: 0.78, blue: 0.92)
        case .evening: tint = RGB(red: 0.86, green: 0.58, blue: 0.42)
        case .lateNight: tint = RGB(red: 0.35, green: 0.42, blue: 0.72)
        }
        return (tint, tint)
    }
}
