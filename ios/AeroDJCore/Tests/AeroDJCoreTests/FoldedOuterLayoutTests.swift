import XCTest
@testable import AeroDJCore

final class FoldedOuterLayoutTests: XCTestCase {

    func testPlayRingFitsInsideTheTransportCapsule() {
        XCTAssertEqual(FoldedOuterLayout.playSide, 64)
        XCTAssertEqual(FoldedOuterLayout.playRingWidth, 6)
        XCTAssertEqual(FoldedOuterLayout.playOuterSide, 76)
        XCTAssertLessThanOrEqual(FoldedOuterLayout.playOuterSide, FoldedOuterLayout.transportHeight)
        XCTAssertEqual(FoldedOuterLayout.transportHeight, 80)
        XCTAssertEqual(FoldedOuterLayout.transportRadius, 40)
        XCTAssertEqual(FoldedOuterLayout.skipSide, 44)
    }

    func testMockupGuttersAndRadii() {
        XCTAssertEqual(FoldedOuterLayout.contentInset, 24)
        XCTAssertEqual(FoldedOuterLayout.artInset, 30)
        XCTAssertEqual(FoldedOuterLayout.artRadius, 28)
        XCTAssertEqual(FoldedOuterLayout.upNextHeight, 44)
        XCTAssertEqual(FoldedOuterLayout.upNextRadius, 22)
        XCTAssertEqual(FoldedOuterLayout.playRingOpacity, 0.25, accuracy: 0.0001)
    }

    func testOnAirComesOnlyFromTheStateLabel() {
        XCTAssertEqual(FoldedOuterLayout.status(of: .speaking(includesBriefing: false)),
                       .onAir("On Air"))
        XCTAssertEqual(FoldedOuterLayout.status(of: .speaking(includesBriefing: true)),
                       .onAir("On Air"))
        // The same function, fed only the label, matches. A second flag is not consulted.
        XCTAssertEqual(FoldedOuterLayout.status(onAirLabel: DJStudioState.speaking(includesBriefing: false).onAirLabel),
                       .onAir("On Air"))
    }

    func testIdlePreparingAndReadyAreMicDownNeverOnAir() {
        let quiet: [DJStudioState] = [
            .idle,
            .preparing(includesBriefing: false),
            .preparing(includesBriefing: true),
            .ready(includesBriefing: false, seconds: 24),
            .ready(includesBriefing: true, seconds: 8),
        ]
        for state in quiet {
            XCTAssertEqual(FoldedOuterLayout.status(of: state), .micDown, "\(state)")
            XCTAssertNil(state.onAirLabel, "\(state) must not publish an On Air label")
            XCTAssertFalse(state.isOnAir, "\(state)")
        }
    }

    func testAFailedBreakIsAQuietSkip() {
        let failed: [DJStudioState] = [
            .failed(.voiceFailed),
            .failed(.budgetReached),
            .failed(.consentReviewRequired(pendingCount: 1)),
        ]
        for state in failed {
            XCTAssertEqual(FoldedOuterLayout.status(of: state), .micDown, "\(state)")
            XCTAssertNil(state.onAirLabel, "a failed break must not light On Air")
        }
    }

    func testAnEmptyOrNilLabelIsNeverOnAir() {
        XCTAssertEqual(FoldedOuterLayout.status(onAirLabel: nil), .micDown)
        XCTAssertEqual(FoldedOuterLayout.status(onAirLabel: ""), .micDown)
        XCTAssertEqual(FoldedOuterLayout.status(onAirLabel: "On Air"), .onAir("On Air"))
    }

    func testTheReskinIsOffInReleaseAndOffWithoutTheFlag() {
        XCTAssertFalse(FoldedOuterLayout.enabled(arguments: [], defaultsFlag: false, isDebug: false))
        XCTAssertFalse(FoldedOuterLayout.enabled(arguments: [FoldedOuterLayout.enableArgument],
                                                defaultsFlag: true, isDebug: false),
                       "release never turns the reskin on")
        XCTAssertFalse(FoldedOuterLayout.enabled(arguments: [], defaultsFlag: false, isDebug: true))
        XCTAssertTrue(FoldedOuterLayout.enabled(arguments: [FoldedOuterLayout.enableArgument],
                                               defaultsFlag: false, isDebug: true))
        XCTAssertTrue(FoldedOuterLayout.enabled(arguments: [], defaultsFlag: true, isDebug: true))
    }

    /// compactBody and FoldedStyle stay the iPhone path: this file must not rewrite their tokens.
    func testFoldedStyleTokensOnTheCompactPathAreUnchanged() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: iosRoot.appendingPathComponent("AeroDJ/FoldedPlayer.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("static let artRadius: CGFloat = 24"))
        XCTAssertTrue(source.contains("static let contentInset: CGFloat = 32"))
        XCTAssertTrue(source.contains("static let toolbarHeight: CGFloat = 52"))
        XCTAssertTrue(source.contains("private func compactBody(in size: CGSize)"))
        // The reskin is gated; the default phone branch still calls compactBody.
        XCTAssertTrue(source.contains("compactBody(in: geo.size)"))
        XCTAssertTrue(source.contains("FoldedOuterLayout.isEnabled"))
        // On Air in the new status helper is only ever taken from onAirLabel.
        let helper = try String(contentsOf: iosRoot.appendingPathComponent(
            "AeroDJCore/Sources/AeroDJCore/Studio/FoldedOuterLayout.swift"), encoding: .utf8)
        XCTAssertTrue(helper.contains("status(onAirLabel:"))
        XCTAssertFalse(helper.contains("isOnAir ?"),
                       "do not derive the pill from isOnAir; use onAirLabel only")
    }
}
