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
                                                                    containerHeight: h, isPhoneIdiom: true),
                              "\(w)×\(h) regular \(regular)")
                XCTAssertTrue(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: regular, containerWidth: w,
                                                                    containerHeight: h, hasFold: true),
                              "\(w)×\(h) regular \(regular) hinge")
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
                    // Every iPhone is the phone idiom: still never the Duo Stations.
                    XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: regular, containerWidth: w,
                                                                         containerHeight: h, hasFold: fold,
                                                                         isPhoneIdiom: true),
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
                    for phone in [false, true] {
                        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: regular, containerWidth: w,
                                                                containerHeight: h, accessibilityTextSize: ax,
                                                                isPhoneIdiom: phone),
                                       old, "\(w)×\(h) regular \(regular) ax \(ax) phone \(phone)")
                    }
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

    /// Orion's idiom-or-hinge gate: an iPad window at regular width with no hinge gets exactly
    /// today's result at open-Duo sizes too (Split View slices 778 × 820 and 790 × 834, a
    /// Stage Manager 900 × 700, the device's 951 × 669): no Duo Stations, the rail since #542,
    /// the stacked Studio at AX sizes.
    func testIPadWindowsWithoutHingeKeepTodaysResult() {
        for (w, h) in [(790.0, 834.0), (778, 820), (900, 700), (951, 669), (669, 951), (820, 640), (640, 820)] {
            XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: w,
                                                                 containerHeight: h), "\(w)×\(h)")
            let placement = FoldedColumnLayout.controlPlacement(containerWidth: w, containerHeight: h)
            let studioOpen = w >= StudioLayoutMetrics.studioMinWidth
            XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: w, containerHeight: h,
                                                    accessibilityTextSize: true),
                           studioOpen ? .studioStacked : (placement == .duoHorizontal ? .duoHorizontal : .centredColumn),
                           "\(w)×\(h) AX")
            XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: w, containerHeight: h,
                                                    accessibilityTextSize: false),
                           placement == .duoHorizontal ? .duoHorizontal : .studio, "\(w)×\(h)")
        }
    }

    /// A large open Duo window (the @2x reading, 1426 × 1003) is told from a 13" iPad by the
    /// phone idiom or a reported fold.
    func testLargeOpenDuoNeedsIdiomOrFold() {
        XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: 1426,
                                                             containerHeight: 1003))
        XCTAssertTrue(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: 1426,
                                                            containerHeight: 1003, isPhoneIdiom: true))
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
                                                        accessibilityTextSize: true, isPhoneIdiom: true), .duoHorizontal,
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

/// Build 54 follow-up (-Nova): the player's open-Duo rail and the leading status column.
final class OpenDuoPlayerRailTests: XCTestCase {
    func testOpenDuoRailOnlyOnOpenDuoSizedBodies() {
        // The player's reader under the navigation bar on the open Duo.
        for (w, h) in [(951.0, 619.0), (951, 669), (669, 901), (820, 576), (640, 770)] {
            XCTAssertTrue(FoldedColumnLayout.usesOpenDuoRail(containerWidth: w, containerHeight: h), "\(w)×\(h)")
        }
        // Full-screen iPads keep today's rail; phone widths never reach the Duo body.
        for (w, h) in [(1180.0, 770.0), (1194, 784), (1376, 982), (1024, 1316), (440, 900), (932, 0), (.nan, 600)] {
            XCTAssertFalse(FoldedColumnLayout.usesOpenDuoRail(containerWidth: w, containerHeight: h), "\(w)×\(h)")
        }
    }

    func testLeadingStatusColumnMovesTheLeadingPageOnly() {
        let flat = DuoStationsLayout.geometry(containerWidth: 951, containerHeight: 669)
        let turned = DuoStationsLayout.geometry(containerWidth: 951, containerHeight: 669, leadingInset: 73)
        XCTAssertEqual(flat.pages[0].minX, DuoStationsLayout.leadingGutter)
        XCTAssertEqual(turned.pages[0].minX, DuoStationsLayout.leadingGutter + 73)
        XCTAssertEqual(turned.pages[1], flat.pages[1])
        XCTAssertEqual(turned.railMinX, flat.railMinX)
        // Upright too.
        let upright = DuoStationsLayout.geometry(containerWidth: 669, containerHeight: 951, leadingInset: 40)
        XCTAssertEqual(upright.pages[0].minX, DuoStationsLayout.leadingGutter + 40)
        // The default is the old geometry.
        XCTAssertEqual(DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640, leadingInset: 0),
                       DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640))
    }
}

/// Build 54 (Orion, -Nova): the hardware-model signal folded into `isPhoneIdiom`.
final class DeviceModelTests: XCTestCase {
    func testPhoneModels() {
        for id in ["iPhone17,3", "iPhone18,1", "iPhone"] {
            XCTAssertTrue(DeviceModel.isPhoneModel(identifier: id), id)
        }
        for id in ["iPad14,8", "iPad16,3", "arm64", "x86_64", "", "iphone17,3", "Watch7,1"] {
            XCTAssertFalse(DeviceModel.isPhoneModel(identifier: id), id)
        }
    }

    func testSimulatorReadsTheSimulatedModel() {
        XCTAssertEqual(DeviceModel.resolvedIdentifier(machine: "arm64", simulatorModel: "iPad16,3"), "iPad16,3")
        XCTAssertEqual(DeviceModel.resolvedIdentifier(machine: "x86_64", simulatorModel: "iPhone17,3"), "iPhone17,3")
        XCTAssertEqual(DeviceModel.resolvedIdentifier(machine: "arm64", simulatorModel: nil), "arm64")
        XCTAssertEqual(DeviceModel.resolvedIdentifier(machine: "arm64", simulatorModel: ""), "arm64")
        // On a device the machine wins, whatever the environment says.
        XCTAssertEqual(DeviceModel.resolvedIdentifier(machine: "iPhone17,3", simulatorModel: "iPad16,3"), "iPhone17,3")
        XCTAssertFalse(DeviceModel.isPhoneModel(identifier:
            DeviceModel.resolvedIdentifier(machine: "arm64", simulatorModel: "iPad16,3")))
    }
}
