import XCTest
@testable import AeroDJCore

// MARK: Sentinel's #410 n4: the Settings row is the purge-all's app caller

final class PersonalDataResetTests: XCTestCase {
    private final class CountingReset: PersonalNarrationResetting, @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var calls: Int { lock.withLock { n } }
        func purgeAllPersonalNarration() async { lock.withLock { n += 1 } }
    }

    func testTheRowRunsThePurgeAllOnce() async {
        let reset = CountingReset()
        await PersonalDataReset.run(reset)
        XCTAssertEqual(reset.calls, 1)
    }

    /// Through the production purger: personal clips go, generic clips stay, and the `.all`
    /// listeners run (location is withdrawn).
    func testTheProductionPurgerDeletesPersonalClipsAndWithdrawsLocation() async {
        let cache = InMemoryAudioCache()
        await cache.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v",
                                      sourceItemIDs: [UUID()]), for: "personal")
        await cache.store(CachedAudio(data: Data([2]), seconds: 1, providerID: "device", voiceID: "v"), for: "generic")
        let feed = NarrationPurgeFeed()
        let store = LocalAreaStore.inMemory()
        store.chooseManual("Saint Paul, MN")
        let listening = store.listen(to: feed)
        defer { listening.cancel() }
        await PersonalDataReset.run(NarrationPurger(cache: cache, preparer: nil, revocations: NarrationRevocations(),
                                                    feed: feed))
        for _ in 0..<500 where store.consent != .declined { await Task.yield() }
        let personal = await cache.audio(for: "personal")
        let generic = await cache.audio(for: "generic")
        XCTAssertNil(personal)
        XCTAssertNotNil(generic, "generic clips are not personal data")
        XCTAssertEqual(store.consent, .declined, "the purge-all reached the location store")
        XCTAssertNil(store.manualPlace)
    }

    func testTheCopySaysWhatGoesAndWhatStays() {
        XCTAssertEqual(PersonalDataReset.title, "Delete DJ clips, ratings and location")
        XCTAssertEqual(PersonalDataReset.message, "Deletes the DJ's spoken clips and planned breaks that mention your calendar, notes or shared items, your song ratings, your saved location and saved news headlines. It doesn't delete the shared items themselves, your review choices, play history or search text. Your stations and settings stay.")
        XCTAssertTrue(PersonalDataReset.message.contains("song ratings"))
        XCTAssertTrue(PersonalDataReset.message.contains("saved location"))
        XCTAssertFalse(PersonalDataReset.title.contains("my DJ data"), "owner: the row names only what it clears")
        XCTAssertTrue(PersonalDataReset.message.contains("Your stations and settings stay."))
        XCTAssertTrue(PersonalDataReset.footer.contains("can't be undone"))
    }

    // App wiring (source checks).

    func testSettingsHasTheRowAndTheAppPassesTheProductionPurger() throws {
        let settings = try appSource("SettingsView.swift")
        XCTAssertTrue(settings.contains("PersonalDataResetSection(purger: personalDataReset)"))
        let section = try body(settings, "struct PersonalDataResetSection: View {")
        XCTAssertTrue(section.contains("confirmationDialog("), "one tap never deletes: it confirms first")
        XCTAssertTrue(section.contains("await PersonalDataReset.run(purger)"))
        XCTAssertTrue(section.contains("role: .destructive"))
        let list = try appSource("StationListView.swift")
        XCTAssertTrue(list.contains("personalDataReset: dependencies.purger"))
        let deps = try appSource("AppDependencies.swift")
        XCTAssertTrue(deps.contains("let purger: NarrationPurger"))
        XCTAssertTrue(deps.contains("localFacts: localFacts,\n            purger: purger)"), "live hands its purger to the app")
        XCTAssertTrue(deps.contains("in the test station\n            purger: purger)"), "and so does the test station")
    }
}

// MARK: Helpers

private func appSource(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

/// From `marker` to the first line that closes a member at four spaces of indent.
private func body(_ source: String, _ marker: String) throws -> String {
    let start = try XCTUnwrap(source.range(of: marker), "missing \(marker)")
    let rest = source[start.lowerBound...]
    let end = try XCTUnwrap(rest.range(of: "\n    }\n") ?? rest.range(of: "\n}\n"), "no end for \(marker)")
    return String(rest[..<end.upperBound])
}
