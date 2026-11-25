import XCTest
@testable import AeroDJCore

/// Pins the #462 wash colours and checks WCAG AA over the left-column backdrop.
final class DayWashPaletteTests: XCTestCase {

    /// Exact RGB values shipped in `DuoDayWashFill` (#462, 4f6367e7).
    private let shipped: [DayPart: (red: Double, green: Double, blue: Double)] = [
        .earlyMorning: (0.96, 0.78, 0.62),
        .morning: (0.98, 0.86, 0.55),
        .afternoon: (0.62, 0.78, 0.92),
        .evening: (0.86, 0.58, 0.42),
        .lateNight: (0.35, 0.42, 0.72),
    ]

    func testEveryDayPartMapsToTheShippedRGBValues() {
        XCTAssertEqual(Set(shipped.keys), Set(DayPart.allCases))
        for part in DayPart.allCases {
            let colors = DayWashPalette.colors(for: part)
            let want = shipped[part]!
            assertRGB(colors.top, want, part, "top")
            assertRGB(colors.bottom, want, part, "bottom")
        }
    }

    /// Composite the wash at the strongest point drawn on screen (the top stop at 0.9,
    /// then `DuoPresentation.washOpacity` 0.16) over `FoldedStyle.background` (#060607),
    /// the left column's near-black backdrop. The artwork bleed is track-dependent and
    /// is left out. Text colours are the ones `FoldedTitleBlock` draws on that column:
    /// primary `.white` (title, `.title2` bold — large text, 3:1 would suffice) and
    /// secondary `FoldedStyle.secondaryInk` (artist, `.body` — 4.5:1). Both must clear
    /// 4.5:1. Colours are not changed if a pair fails; the test just reports it.
    func testWashOverTheLeftColumnClearsWCAGAA() {
        // FoldedStyle.background in FoldedPlayer.swift.
        let backdrop = DayWashPalette.RGB(red: 6 / 255, green: 6 / 255, blue: 7 / 255)
        // FoldedTitleBlock title: `.foregroundStyle(.white)`.
        let primary = DayWashPalette.RGB(red: 1, green: 1, blue: 1)
        // FoldedStyle.secondaryInk = Color.white.opacity(0.6), used on the artist line
        // and the TEST STATION tag. Composited over the washed backdrop.
        let secondaryOpacity = 0.6
        // DuoDayWashFill top stop, then the view opacity.
        let topStopOpacity = 0.9
        let washOpacity = DuoPresentation.washOpacity(reduceTransparency: false)
        XCTAssertEqual(washOpacity, 0.16, accuracy: 1e-12)
        XCTAssertEqual(DuoPresentation.washOpacity(reduceTransparency: true), 0)
        let alpha = topStopOpacity * washOpacity

        for part in DayPart.allCases {
            let tint = DayWashPalette.colors(for: part).top
            let washed = composite(tint, over: backdrop, alpha: alpha)
            let primaryRatio = contrast(primary, washed)
            let secondaryColor = composite(primary, over: washed, alpha: secondaryOpacity)
            let secondaryRatio = contrast(secondaryColor, washed)
            XCTAssertGreaterThanOrEqual(
                primaryRatio, 4.5,
                "\(part) primary (white) on washed #060607 is \(fmt(primaryRatio)):1; colours were not changed"
            )
            XCTAssertGreaterThanOrEqual(
                secondaryRatio, 4.5,
                "\(part) secondary (white at 0.6) on washed #060607 is \(fmt(secondaryRatio)):1; colours were not changed"
            )
        }
    }

    /// The empty-station placeholder also sits on the left column and uses
    /// `AeroDJPalette.onMediaLight` (white) plus opaque `slabSecondary` (#E4D5C5)
    /// when `onSlab` is true (`FoldedPlayer` sets that). Reported alongside the
    /// title-block inks; not a reason to change the wash.
    func testPlaceholderSecondaryOnTheWashClearsWCAGAA() {
        let backdrop = DayWashPalette.RGB(red: 6 / 255, green: 6 / 255, blue: 7 / 255)
        let slabSecondary = DayWashPalette.RGB(red: 0xE4 / 255, green: 0xD5 / 255, blue: 0xC5 / 255)
        let alpha = 0.9 * DuoPresentation.washOpacity(reduceTransparency: false)
        for part in DayPart.allCases {
            let washed = composite(DayWashPalette.colors(for: part).top, over: backdrop, alpha: alpha)
            let ratio = contrast(slabSecondary, washed)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(part) slabSecondary on washed #060607 is \(fmt(ratio)):1; colours were not changed"
            )
        }
    }

    // MARK: - Helpers

    private func assertRGB(_ have: DayWashPalette.RGB,
                           _ want: (red: Double, green: Double, blue: Double),
                           _ part: DayPart, _ end: String) {
        XCTAssertEqual(have.red, want.red, accuracy: 1e-12, "\(part) \(end).red")
        XCTAssertEqual(have.green, want.green, accuracy: 1e-12, "\(part) \(end).green")
        XCTAssertEqual(have.blue, want.blue, accuracy: 1e-12, "\(part) \(end).blue")
    }

    private func composite(_ fg: DayWashPalette.RGB, over bg: DayWashPalette.RGB,
                           alpha: Double) -> DayWashPalette.RGB {
        DayWashPalette.RGB(
            red: fg.red * alpha + bg.red * (1 - alpha),
            green: fg.green * alpha + bg.green * (1 - alpha),
            blue: fg.blue * alpha + bg.blue * (1 - alpha)
        )
    }

    /// WCAG 2 relative luminance contrast, (L1 + 0.05) / (L2 + 0.05).
    private func contrast(_ a: DayWashPalette.RGB, _ b: DayWashPalette.RGB) -> Double {
        let hi = max(luminance(a), luminance(b))
        let lo = min(luminance(a), luminance(b))
        return (hi + 0.05) / (lo + 0.05)
    }

    private func luminance(_ color: DayWashPalette.RGB) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private func fmt(_ ratio: Double) -> String {
        String(format: "%.2f", ratio)
    }
}
