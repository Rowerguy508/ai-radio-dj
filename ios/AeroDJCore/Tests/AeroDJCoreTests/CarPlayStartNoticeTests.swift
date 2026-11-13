import XCTest
@testable import AeroDJCore

/// #438 (-Atlas): a CarPlay station pick that does not start shows a fixed-copy notice instead of
/// silently pushing an empty Now Playing. Pure decisions; the CarPlay alert itself is iOS-only.
final class CarPlayStartNoticeTests: XCTestCase {
    private let failures: [CreatedStationOpenOutcome] = [
        .notStarted(.notReadyInTime), .notStarted(.buildFailed),
    ]

    func testATimedOutOrFailedBuildSaysCouldNotStartTheStationWithTryAgain() throws {
        for outcome in failures {
            let notice = try XCTUnwrap(CarPlayScreen.startNotice(for: outcome, stationName: "Morning Calm",
                                                                 access: .authorized), "\(outcome)")
            XCTAssertEqual(notice.titleVariants, ["Couldn't start Morning Calm. Try again.", "Couldn't start station"])
            XCTAssertTrue(notice.offersRetry, "\(outcome)")
            XCTAssertEqual(notice.visibleText,
                           ["Couldn't start Morning Calm. Try again.", "Couldn't start station", "Try Again", "OK"])
        }
    }

    func testTheOtherFailuresThePhoneToastsAlsoShowTheNotice() {
        for outcome in [CreatedStationOpenOutcome.notStarted(.noStation), .notApplied] {
            XCTAssertEqual(CarPlayScreen.startNotice(for: outcome, stationName: "A", access: .authorized)?.titleVariants.first,
                           "Couldn't start A. Try again.", "\(outcome)")
        }
    }

    func testStartsResumesNoOpsAndReplacedPicksShowNoNotice() {
        let quiet: [CreatedStationOpenOutcome] = [
            .started(songs: 1, waited: true), .started(songs: 12, waited: false), .resumed, .alreadyPlaying,
            .restoredOnly, .notStarted(.superseded), .notStarted(.playbackBegan), .notStarted(.notAvailableYet),
        ]
        for outcome in quiet {
            XCTAssertNil(CarPlayScreen.startNotice(for: outcome, stationName: "A", access: .authorized), "\(outcome)")
        }
    }

    func testEveryNoStartReasonIsDecided() {
        // A new reason must be placed on purpose: the notice follows the phone toast's rule.
        for reason in CreatedStationNoStartReason.allCases {
            let notice = CarPlayScreen.startNotice(for: .notStarted(reason), stationName: "A", access: .authorized)
            XCTAssertEqual(notice != nil, CreatedStationOpenOutcome.notStarted(reason).warrantsStartFailureNotice,
                           reason.rawValue)
        }
    }

    func testWithoutAppleMusicAccessItSaysConnectAndOffersNoRetry() throws {
        for access in [PlaybackAccess.needsAuthorization, .denied, .subscriptionRequired] {
            let notice = try XCTUnwrap(CarPlayScreen.startNotice(for: .notStarted(.buildFailed), stationName: "A",
                                                                 access: access))
            XCTAssertEqual(notice.titleVariants, [StationStartNotice.connectAppleMusic, CarPlayStartNotice.shortTitle])
            XCTAssertFalse(notice.offersRetry)
            XCTAssertEqual(notice.visibleText.last, "OK")
        }
        // Still checking access is treated like authorized (the start itself already asked).
        XCTAssertEqual(CarPlayScreen.startNotice(for: .notStarted(.buildFailed), stationName: "A",
                                                 access: .checking)?.offersRetry, true)
    }

    func testTheNoticeCarriesOnlyFixedCopyAndTheRowName() throws {
        let lines = try XCTUnwrap(CarPlayScreen.startNotice(for: .notStarted(.notReadyInTime),
                                                            stationName: "Road\nTrip\t Mix", access: .authorized))
        XCTAssertEqual(lines.titleVariants.first, "Couldn't start Road Trip Mix. Try again.")
        let blank = try XCTUnwrap(CarPlayScreen.startNotice(for: .notStarted(.buildFailed), stationName: " \n ",
                                                            access: .authorized))
        XCTAssertEqual(blank.titleVariants.first, "Couldn't start that station. Try again.")
        for text in lines.visibleText + blank.visibleText {
            XCTAssertFalse(text.contains("\n"), text)
            XCTAssertLessThanOrEqual(text.count, 64, text)
        }
    }

    // MARK: the pick that finishes decides

    func testTheLatestFailingPickShowsTheNoticeAndDoesNotPushNowPlaying() {
        var picks = CarPlayPickTracker()
        let pick = picks.begin()
        guard case .notice(let notice) = picks.finish(pick, outcome: .notStarted(.notReadyInTime),
                                                      stationName: "Late Night", access: .authorized) else {
            return XCTFail("a failed pick shows the notice")
        }
        XCTAssertEqual(notice.titleVariants.first, "Couldn't start Late Night. Try again.")
    }

    func testAStartedPickStillPushesNowPlaying() {
        var picks = CarPlayPickTracker()
        let pick = picks.begin()
        XCTAssertEqual(picks.finish(pick, outcome: .started(songs: 1, waited: true), stationName: "A",
                                    access: .authorized), .showNowPlaying)
        let again = picks.begin()
        XCTAssertEqual(picks.finish(again, outcome: .alreadyPlaying, stationName: "A", access: .authorized),
                       .showNowPlaying)
    }

    func testNoStationQueuePushesNowPlayingAsBefore() {
        var picks = CarPlayPickTracker()
        let pick = picks.begin()
        XCTAssertEqual(picks.finish(pick, outcome: nil, stationName: "A", access: .authorized), .showNowPlaying)
    }

    func testAnOlderPickThatFailsAfterANewerPickShowsNothing() {
        var picks = CarPlayPickTracker()
        let older = picks.begin()
        let newer = picks.begin()
        XCTAssertEqual(picks.finish(older, outcome: .notStarted(.notReadyInTime), stationName: "A",
                                    access: .authorized), .stale)
        XCTAssertEqual(picks.finish(older, outcome: .started(songs: 1, waited: true), stationName: "A",
                                    access: .authorized), .stale)
        guard case .notice = picks.finish(newer, outcome: .notStarted(.buildFailed), stationName: "B",
                                          access: .authorized) else {
            return XCTFail("the newer pick decides")
        }
    }

    // MARK: the app wiring (iOS-only code; a source check, not a CarPlay run)

    func testTheCarPlaySceneShowsTheNoticeFromTheTrackerAndRetriesTheSamePick() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/CarPlaySceneDelegate.swift")
        let code = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for required in [
            "picks.begin()",
            "picks.finish(pick, outcome: outcome, stationName: row.name, access: access(music.authState))",
            "case .notice(let notice):",
            "showStartNotice(notice, retrying: row)",
            "CPAlertTemplate(titleVariants: notice.titleVariants, actions: actions)",
            "CarPlayStartNotice.retryTitle",
            "CarPlayStartNotice.dismissTitle",
            "presentTemplate(alert",
            "outcome = await queue.openCreatedStation(.userTap",
            "outcome = await queue.openBuiltInStation(.userTap",
        ] {
            XCTAssertTrue(code.contains(required), required)
        }
        // Now Playing is pushed only from the tracker's `.showNowPlaying` (and the list's button).
        let pickBody = try XCTUnwrap(code.range(of: "fileprivate func pick(").map { code[$0.lowerBound...] })
        let end = try XCTUnwrap(pickBody.range(of: "private func showStartNotice("))
        let pickOnly = String(pickBody[..<end.lowerBound])
        XCTAssertEqual(pickOnly.components(separatedBy: "showNowPlaying()").count - 1, 1, pickOnly)
        XCTAssertTrue(pickOnly.contains("case .showNowPlaying:\n            showNowPlaying()"), pickOnly)
    }
}
