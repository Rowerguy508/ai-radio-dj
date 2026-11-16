import XCTest
@testable import AeroDJCore

/// #465 item 9: the glass decision table for Reduce Transparency, Increase Contrast and
/// Reduce Motion, for play (the only tinted control), every other control and surfaces.
final class GlassTreatmentTests: XCTestCase {
    private let none = GlassAccessibility()

    func testAllCombinationsHasEightDistinctEntries() {
        XCTAssertEqual(GlassAccessibility.allCombinations.count, 8)
        XCTAssertEqual(Set(GlassAccessibility.allCombinations).count, 8)
    }

    // MARK: Defaults (iOS 26, no settings)

    func testPlayIsTheOnlyProminentTintedControl() {
        let play = GlassTreatment.control(.primary, accessibility: none, glassAvailable: true)
        XCTAssertEqual(play, GlassTreatment(fill: .glassProminent, isTinted: true, isInteractive: true,
                                            hairline: .none, animates: true))
        let other = GlassTreatment.control(.secondary, accessibility: none, glassAvailable: true)
        XCTAssertEqual(other, GlassTreatment(fill: .glass, isTinted: false, isInteractive: true,
                                             hairline: .none, animates: true))
    }

    func testSurfacesAreGlassNeverTintedNeverInteractive() {
        for a in GlassAccessibility.allCombinations {
            for available in [true, false] {
                let t = GlassTreatment.surface(accessibility: a, glassAvailable: available)
                XCTAssertFalse(t.isTinted, "\(a)")
                XCTAssertFalse(t.isInteractive, "\(a)")
                XCTAssertNotEqual(t.fill, .glassProminent, "\(a)")
            }
        }
        XCTAssertEqual(GlassTreatment.surface(accessibility: none, glassAvailable: true).fill, .glass)
    }

    func testNoSecondaryControlIsEverTintedOrProminent() {
        for a in GlassAccessibility.allCombinations {
            for available in [true, false] {
                let t = GlassTreatment.control(.secondary, accessibility: a, glassAvailable: available)
                XCTAssertFalse(t.isTinted, "\(a)")
                XCTAssertNotEqual(t.fill, .glassProminent, "\(a)")
            }
        }
    }

    func testPlayIsTintedInEveryMode() {
        for a in GlassAccessibility.allCombinations {
            for available in [true, false] {
                XCTAssertTrue(GlassTreatment.control(.primary, accessibility: a, glassAvailable: available).isTinted,
                              "\(a) available=\(available)")
            }
        }
    }

    // MARK: Reduce Transparency

    func testReduceTransparencyIsSolidForEverything() {
        let a = GlassAccessibility(reduceTransparency: true)
        for available in [true, false] {
            XCTAssertEqual(GlassTreatment.control(.primary, accessibility: a, glassAvailable: available).fill, .solid)
            XCTAssertEqual(GlassTreatment.control(.secondary, accessibility: a, glassAvailable: available).fill, .solid)
            XCTAssertEqual(GlassTreatment.surface(accessibility: a, glassAvailable: available).fill, .solid)
        }
        XCTAssertEqual(GlassTreatment.surface(accessibility: a, glassAvailable: true).hairline, .standard)
    }

    // MARK: Increase Contrast

    func testIncreaseContrastIsSolidWithAStrongEdge() {
        let a = GlassAccessibility(increaseContrast: true)
        for available in [true, false] {
            for t in [GlassTreatment.control(.primary, accessibility: a, glassAvailable: available),
                      GlassTreatment.control(.secondary, accessibility: a, glassAvailable: available),
                      GlassTreatment.surface(accessibility: a, glassAvailable: available)] {
                XCTAssertEqual(t.fill, .solid)
                XCTAssertEqual(t.hairline, .strong)
                XCTAssertFalse(t.isInteractive)
            }
        }
        XCTAssertGreaterThan(GlassHairline.strong.lineWidth, GlassHairline.standard.lineWidth)
        XCTAssertGreaterThan(GlassHairline.strong.opacity, GlassHairline.standard.opacity)
    }

    // MARK: Reduce Motion

    func testReduceMotionKeepsGlassButStopsMorphAndBounce() {
        let a = GlassAccessibility(reduceMotion: true)
        let play = GlassTreatment.control(.primary, accessibility: a, glassAvailable: true)
        XCTAssertEqual(play.fill, .glassProminent)
        XCTAssertFalse(play.isInteractive)
        XCTAssertFalse(play.animates)
        let other = GlassTreatment.control(.secondary, accessibility: a, glassAvailable: true)
        XCTAssertEqual(other.fill, .glass)
        XCTAssertFalse(other.isInteractive)
        XCTAssertFalse(other.animates)
    }

    func testNothingAnimatesOrIsInteractiveWithReduceMotion() {
        for a in GlassAccessibility.allCombinations where a.reduceMotion {
            for available in [true, false] {
                for t in [GlassTreatment.control(.primary, accessibility: a, glassAvailable: available),
                          GlassTreatment.control(.secondary, accessibility: a, glassAvailable: available),
                          GlassTreatment.surface(accessibility: a, glassAvailable: available)] {
                    XCTAssertFalse(t.animates, "\(a)")
                    XCTAssertFalse(t.isInteractive, "\(a)")
                }
            }
        }
    }

    // MARK: Before iOS 26

    func testWithoutGlassTheExistingLookIsKept() {
        let play = GlassTreatment.control(.primary, accessibility: none, glassAvailable: false)
        XCTAssertEqual(play, GlassTreatment(fill: .legacy, isTinted: true, isInteractive: false,
                                            hairline: .standard, animates: true))
        XCTAssertEqual(GlassTreatment.control(.secondary, accessibility: none, glassAvailable: false).fill, .legacy)
        XCTAssertEqual(GlassTreatment.surface(accessibility: none, glassAvailable: false).fill, .legacy)
    }

    // MARK: Full table

    /// Every combination, written out, so a rule change shows up as a table diff.
    func testFullDecisionTableOnIOS26() {
        // (RT, IC, RM) -> (play fill, other fill, surface fill, hairline, interactive, animates)
        typealias Row = (GlassFill, GlassFill, GlassFill, GlassHairline, Bool, Bool)
        let expected: [GlassAccessibility: Row] = [
            .init(reduceTransparency: false, increaseContrast: false, reduceMotion: false): (.glassProminent, .glass, .glass, .none, true, true),
            .init(reduceTransparency: false, increaseContrast: false, reduceMotion: true): (.glassProminent, .glass, .glass, .none, false, false),
            .init(reduceTransparency: false, increaseContrast: true, reduceMotion: false): (.solid, .solid, .solid, .strong, false, true),
            .init(reduceTransparency: false, increaseContrast: true, reduceMotion: true): (.solid, .solid, .solid, .strong, false, false),
            .init(reduceTransparency: true, increaseContrast: false, reduceMotion: false): (.solid, .solid, .solid, .standard, false, true),
            .init(reduceTransparency: true, increaseContrast: false, reduceMotion: true): (.solid, .solid, .solid, .standard, false, false),
            .init(reduceTransparency: true, increaseContrast: true, reduceMotion: false): (.solid, .solid, .solid, .strong, false, true),
            .init(reduceTransparency: true, increaseContrast: true, reduceMotion: true): (.solid, .solid, .solid, .strong, false, false),
        ]
        XCTAssertEqual(expected.count, 8)
        for a in GlassAccessibility.allCombinations {
            guard let row = expected[a] else { return XCTFail("missing \(a)") }
            let play = GlassTreatment.control(.primary, accessibility: a, glassAvailable: true)
            let other = GlassTreatment.control(.secondary, accessibility: a, glassAvailable: true)
            let surface = GlassTreatment.surface(accessibility: a, glassAvailable: true)
            XCTAssertEqual(play.fill, row.0, "play \(a)")
            XCTAssertEqual(other.fill, row.1, "other \(a)")
            XCTAssertEqual(surface.fill, row.2, "surface \(a)")
            XCTAssertEqual(play.hairline, row.3, "hairline \(a)")
            XCTAssertEqual(other.hairline, row.3, "hairline \(a)")
            XCTAssertEqual(play.isInteractive, row.4, "interactive \(a)")
            XCTAssertEqual(other.isInteractive, row.4, "interactive \(a)")
            XCTAssertEqual(play.animates, row.5, "animates \(a)")
        }
    }
}
