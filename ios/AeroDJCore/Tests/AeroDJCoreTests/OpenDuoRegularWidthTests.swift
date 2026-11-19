import XCTest
@testable import AeroDJCore

/// Build 54 (owner: "I am not seeing any changes to the ui"): the open Duo reports the regular
/// width class at ≈ 951 × 669 pt (@3x shots), so the compact-only gates never drew the open-Duo
/// Stations. These pin the measured gate at either class, keep every iPhone and the closed Duo
/// where they were, and keep full-screen iPads off the Duo screens. -Nova
final class OpenDuoRegularWidthTests: XCTestCase {
    /// Every iPhone and the closed Duo, portrait and landscape (largest: 440 × 956 / 956 × 440).
    private let phones: [(Double, Double)] = [
        (320, 568), (375, 667), (375, 812), (390, 844), (393, 852), (402, 874), (414, 896), (428, 926),
        (430, 932), (440, 956),
        (568, 320), (667, 375), (812, 375), (844, 390), (852, 393), (874, 402), (896, 414), (926, 428),
        (932, 430), (956, 440),
    ]
    /// The open Duo: the device window from the owner's shots, the sim bands, and the @2x reading.
    private let openDuo: [(Double, Double)] = [(951, 669), (669, 951), (820, 640), (640, 820)]
    /// Full-screen iPads, both orientations (mini, Air 11", Pro 11", Air/Pro 13").
    private let iPads: [(Double, Double)] = [
        (744, 1133), (1133, 744), (820, 1180), (1180, 820), (834, 1194), (1194, 834),
        (1024, 1366), (1366, 1024), (1032, 1376), (1376, 1032),
    ]

    func testThreshold() {
        XCTAssertEqual(FoldedColumnLayout.openDuoMaxSide, 1000)
        XCTAssertEqual(DuoStationsLayout.statusColumnClearance, 88)
    }

    func testOpenDuoGetsTheDuoStationsAtEitherWidthClass() {
        for (w, h) in openDuo {
            XCTAssertTrue(FoldedColumnLayout.isOpenDuoWindow(containerWidth: w, containerHeight: h), "\(w)×\(h)")
            for regular in [false, true] {
                XCTAssertTrue(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: regular, containerWidth: w,
                                                                    containerHeight: h), "\(w)×\(h) regular \(regular)")
            }
        }
    }

    /// The iPhone and the closed Duo are on the same side as before at both classes (an iPhone
    /// Plus/Max reports regular width in landscape), with or without a fold signal.
    func testIPhoneAndClosedDuoUnchanged() {
        for (w, h) in phones {
            XCTAssertFalse(FoldedColumnLayout.isOpenDuoWindow(containerWidth: w, containerHeight: h), "\(w)×\(h)")
            XCTAssertNotEqual(FoldedColumnLayout.controlPlacement(containerWidth: w, containerHeight: h), .duoHorizontal)
            for regular in [false, true] {
                for fold in [false, true] {
                    XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: regular, containerWidth: w,
                                                                         containerHeight: h, hasFold: fold),
                                   "\(w)×\(h) regular \(regular) fold \(fold)")
                }
                for ax in [false, true] {
                    // The pre-build-54 rule, which the phone sizes must still follow.
                    let old: DisplayContinuity.Layout = {
                        switch StudioLayoutMode.resolve(hasRegularWidth: regular, containerWidth: w,
                                                        accessibilityTextSize: ax) {
                        case .studioStacked: return .studioStacked
                        case .studio: return .studio
                        case .compact:
                            switch FoldedColumnLayout.controlPlacement(containerWidth: w, containerHeight: h) {
                            case .phoneBottom: return .phoneBottom
                            case .centredColumn: return .centredColumn
                            case .duoHorizontal: return .duoHorizontal
                            }
                        }
                    }()
                    XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: regular, containerWidth: w,
                                                            containerHeight: h, accessibilityTextSize: ax),
                                   old, "\(w)×\(h) regular \(regular) ax \(ax)")
                }
            }
        }
    }

    /// Full-screen iPads keep the sidebar list (no fold signal) and keep their player routing
    /// exactly as on integration e920a35c: wide-and-tall is the rail since #542 (not the
    /// two-zone Studio), accessibility sizes the stacked Studio.
    func testFullScreenIPadsUnchanged() {
        for (w, h) in iPads {
            XCTAssertFalse(FoldedColumnLayout.isOpenDuoWindow(containerWidth: w, containerHeight: h), "\(w)×\(h)")
            XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: w,
                                                                 containerHeight: h), "\(w)×\(h)")
            XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: w, containerHeight: h,
                                                    accessibilityTextSize: true), .studioStacked, "\(w)×\(h) AX")
            let placement = FoldedColumnLayout.controlPlacement(containerWidth: w, containerHeight: h)
            XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: w, containerHeight: h,
                                                    accessibilityTextSize: false),
                           placement == .duoHorizontal ? .duoHorizontal : .studio, "\(w)×\(h)")
        }
        // A short regular iPad window at the Studio width still opens the two-zone Studio.
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: 1194, containerHeight: 560,
                                                accessibilityTextSize: false), .studio)
    }

    /// An open Duo window longer than `openDuoMaxSide` (the @2x reading, 1426 × 1003) is told from
    /// an iPad only by a reported fold.
    func testLargeOpenDuoNeedsTheFoldSignal() {
        XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: 1426,
                                                             containerHeight: 1003))
        XCTAssertTrue(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: 1426,
                                                            containerHeight: 1003, hasFold: true))
        // Compact is the old rule, fold or not.
        XCTAssertTrue(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: false, containerWidth: 1426,
                                                            containerHeight: 1003))
    }

    /// Accessibility text sizes: the open Duo keeps the rail at regular width, as compact did.
    func testOpenDuoKeepsTheRailAtAccessibilitySizes() {
        for (w, h) in openDuo {
            for regular in [false, true] {
                XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: regular, containerWidth: w, containerHeight: h,
                                                        accessibilityTextSize: true), .duoHorizontal,
                               "\(w)×\(h) regular \(regular)")
                XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: regular, containerWidth: w, containerHeight: h,
                                                        accessibilityTextSize: false), .duoHorizontal)
            }
        }
    }

    func testRailTopClearsATrailingStatusColumnOnly() {
        XCTAssertEqual(DuoStationsLayout.railTopInset(trailingUnsafeWidth: 0), DuoStationsLayout.railVerticalInset)
        XCTAssertEqual(DuoStationsLayout.railTopInset(trailingUnsafeWidth: .nan), DuoStationsLayout.railVerticalInset)
        XCTAssertEqual(DuoStationsLayout.railTopInset(trailingUnsafeWidth: 73), 88)
    }
}
