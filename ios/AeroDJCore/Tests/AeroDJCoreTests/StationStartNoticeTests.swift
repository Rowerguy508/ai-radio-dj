import XCTest
@testable import AeroDJCore

// "Couldn't start that station" toast (-Nova): shown only when the listener's latest created-station
// tap ends with nothing going to play. Never on restore, a boundary switch, a start, or a tap the
// listener replaced. Any new tap or dismiss clears it.

private struct Offline: Error {}

private actor FailingCatalog: StationSeedCatalog {
    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { throw Offline() }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { throw Offline() }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { throw Offline() }
}

private let failures: [CreatedStationOpenOutcome] = [
    .notApplied, .notStarted(.noStation), .notStarted(.notReadyInTime), .notStarted(.buildFailed),
]
private let quiet: [CreatedStationOpenOutcome] = [
    .restoredOnly, .switchesAtBoundary, .started(songs: 10, waited: false), .started(songs: 3, waited: true),
    .notStarted(.playbackBegan), .notStarted(.superseded),
]

// No class-level @MainActor: Linux XCTest discovery (Swift 6.2) aborts casting a @MainActor sync test.
// Sync tests assume main-actor isolation; async tests are @MainActor per test (same as StationQueueFeedTests).
final class StationStartNoticeTests: XCTestCase {
    func testEveryNoStartReasonIsDecided() {
        // A new reason must be classified here on purpose, not fall into the toast by accident.
        XCTAssertEqual(Set(CreatedStationNoStartReason.allCases),
                       [.noStation, .notReadyInTime, .buildFailed, .playbackBegan, .superseded])
    }

    func testAFailedOrTimedOutIdleStartShowsTheToast() {
        MainActor.assumeIsolated {
            for outcome in failures {
                let notice = StationStartNotice()
                notice.finish(tap: notice.beginTap(), outcome: outcome)
                XCTAssertEqual(notice.message, "Couldn't start that station", "\(outcome)")
                XCTAssertEqual(notice.showID, 1, "\(outcome)")
            }
        }
    }

    func testStartsBoundarySwitchesRestoreAndReplacedTapsStayQuiet() {
        MainActor.assumeIsolated {
            for outcome in quiet {
                let notice = StationStartNotice()
                notice.finish(tap: notice.beginTap(), outcome: outcome)
                XCTAssertNil(notice.message, "\(outcome)")
                XCTAssertEqual(notice.showID, 0, "\(outcome)")
            }
        }
    }

    func testANewTapClearsTheToast() {
        MainActor.assumeIsolated {
            let notice = StationStartNotice()
            notice.finish(tap: notice.beginTap(), outcome: .notStarted(.notReadyInTime))
            XCTAssertNotNil(notice.message)
            _ = notice.beginTap()
            XCTAssertNil(notice.message, "the next tap (built-in or created) clears it")
        }
    }

    func testOnlyTheLatestTapMayShowTheToast() {
        MainActor.assumeIsolated {
            let notice = StationStartNotice()
            let first = notice.beginTap()
            let second = notice.beginTap()
            notice.finish(tap: first, outcome: .notStarted(.buildFailed))
            XCTAssertNil(notice.message, "an older tap's late failure is not shown")
            notice.finish(tap: second, outcome: .started(songs: 10, waited: true))
            XCTAssertNil(notice.message)
        }
    }

    func testDismissClearsAndAStaleTimerCannotHideANewerToast() {
        MainActor.assumeIsolated {
            let notice = StationStartNotice()
            notice.finish(tap: notice.beginTap(), outcome: .notApplied)
            let firstShow = notice.showID
            notice.finish(tap: notice.beginTap(), outcome: .notStarted(.buildFailed))
            XCTAssertGreaterThan(notice.showID, firstShow)
            notice.dismiss(showID: firstShow)
            XCTAssertNotNil(notice.message, "the first toast's timer must not hide the second")
            notice.dismiss(showID: notice.showID)
            XCTAssertNil(notice.message)

            notice.finish(tap: notice.beginTap(), outcome: .notApplied)
            notice.dismiss()
            XCTAssertNil(notice.message, "a plain dismiss always hides it")
        }
    }

    func testDisplayDurationIsShort() {
        XCTAssertEqual(StationStartNotice.displayDuration, .seconds(3))
    }

    // End to end with the real starter: a tap whose queue cannot be built toasts; restore does not.
    @MainActor func testATapThatCannotBuildToastsAndRestoreDoesNot() async {
        var created = StationConfiguration.default
        created.seeds = [StationSeed(kind: .artist, catalogID: "a", name: "Secret a", source: .catalog)]
        created = created.validated()
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .default))),
            consent: StaticIntegrationConsent([:]))
        await model.load()
        let feed = StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: FailingCatalog()),
                                            materialize: { $0.map(\.id) }, log: { _ in })
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .milliseconds(50), pollInterval: .milliseconds(1))
        let notice = StationStartNotice()
        var starts = 0

        func open(_ trigger: StationOpenTrigger) async -> CreatedStationOpenOutcome {
            await starter.open(trigger, authorize: {},
                               apply: { await model.applyRecipe(StationRecipe(name: "A Radio", configuration: created)); return true },
                               active: { model.active }, nothingQueued: { true }, start: { _ in starts += 1 })
        }

        let restoreTap = notice.beginTap()
        notice.finish(tap: restoreTap, outcome: await open(.restore))
        XCTAssertNil(notice.message, "restore never toasts")

        let tap = notice.beginTap()
        let outcome = await open(.userTap)
        XCTAssertEqual(outcome, .notStarted(.buildFailed))
        notice.finish(tap: tap, outcome: outcome)
        XCTAssertEqual(notice.message, StationStartNotice.couldNotStart)
        XCTAssertEqual(starts, 0)
    }
}
