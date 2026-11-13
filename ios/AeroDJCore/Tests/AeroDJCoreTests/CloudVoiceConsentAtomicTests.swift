import XCTest
@testable import AeroDJCore

// #441 (-Sentinel): cloud-voice consent is one atomic record. A decline, a legacy two-key value,
// a partial or malformed record, or an old acceptance must never read as the v2 all-lines grant,
// at any point during a write. In-process fakes only: no network, no paid service.

private final class AtomicCloudSpy: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

/// Runs `observer` right after every mutation, before the next one, so a test sees each
/// intermediate persisted state a concurrent renderer could read (the harness from #441).
private final class ObservingDefaults: UserDefaults {
    private let lock = NSLock()
    private var _observer: ((String) -> Void)?
    private var _mutations: [String] = []
    var observer: ((String) -> Void)? {
        get { lock.withLock { _observer } }
        set { lock.withLock { _observer = newValue } }
    }
    var mutations: [String] { lock.withLock { _mutations } }
    func resetMutations() { lock.withLock { _mutations = [] } }

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        lock.withLock { _mutations.append("set \(defaultName)") }
        observer?(defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        super.removeObject(forKey: defaultName)
        lock.withLock { _mutations.append("remove \(defaultName)") }
        observer?(defaultName)
    }
}

final class CloudVoiceConsentAtomicTests: XCTestCase {
    private typealias Store = CloudVoiceConsentStore

    private func suite() throws -> (ObservingDefaults, String) {
        let name = "CloudVoiceConsentAtomicTests.\(UUID().uuidString)"
        return (try XCTUnwrap(ObservingDefaults(suiteName: name)), name)
    }

    private func seedLegacy(_ d: UserDefaults, state: String?, version: Int?) {
        if let state { d.set(state, forKey: Store.stateKey) }
        if let version { d.set(version, forKey: Store.versionKey) }
    }

    private func cue(_ text: String, item: UUID) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: 0, kind: .upcomingEvent, text: text, estimatedSeconds: 3,
                     maxSeconds: 20, sourceItemID: item, source: .calendar, provenance: "calendar:1")
    }

    /// Renders one private calendar line and one catalog transition through `store`'s gate
    /// (`gated(by:)`, the owner and tester live path) and returns what the cloud received.
    private func cloudCalls(_ store: Store) async -> [String] {
        let spy = AtomicCloudSpy()
        let r = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice, leavesDevice: true),
                                       VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                              budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                              revocations: NarrationRevocations()).gated(by: store)
        let event = UUID()
        _ = await r.render(cue("From your calendar: dentist at 3.", item: event), userID: "u", stationID: "s",
                           attribution: .personalContext(itemID: event, source: .calendar, provenance: "calendar:1"))
        let next = NarrationCue(id: UUID(), order: 1, group: 0, kind: .transition, text: "Next up, Song 2.",
                                estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        _ = await r.render(next, userID: "u", stationID: "s", attribution: .trackMetadata(trackIDs: ["t2"], origin: .catalog))
        return spy.received
    }

    // MARK: - The #441 reproduction

    func testAVersionOneAcceptanceDeclinedUnderVersionTwoIsNeverReadableAsAGrant() async throws {
        let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
        seedLegacy(d, state: CloudVoiceConsentState.accepted.rawValue, version: 1)
        let store = Store(defaults: d)
        XCTAssertEqual(store.scope, .noLines, "before the decline")
        var seen: [(String, CloudVoiceConsentState, CloudVoiceScope)] = []
        d.observer = { key in seen.append((key, store.state, store.scope)) }
        store.decline()
        d.observer = nil
        XCTAssertFalse(seen.isEmpty)
        for (key, state, scope) in seen {
            XCTAssertNotEqual(state, .accepted, "readable as accepted right after writing \(key)")
            XCTAssertEqual(scope, .noLines, "readable as all lines right after writing \(key)")
        }
        XCTAssertEqual(store.state, .declined)
        let calls = await cloudCalls(store)
        XCTAssertTrue(calls.isEmpty, "sent after a decline: \(calls)")
    }

    func testADeclineDecidesWithOneSetAndNeverWritesTheLegacyPair() throws {
        let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
        seedLegacy(d, state: CloudVoiceConsentState.accepted.rawValue, version: 1)
        let store = Store(defaults: d)
        d.resetMutations()
        store.decline()
        XCTAssertEqual(d.mutations.filter { $0.hasPrefix("set") }, ["set \(Store.recordKey)"],
                       "the decision is one write of one key")
        XCTAssertEqual(d.mutations.first, "set \(Store.recordKey)", "the record lands before any cleanup")
        XCTAssertNil(d.object(forKey: Store.stateKey))
        XCTAssertNil(d.object(forKey: Store.versionKey))
        XCTAssertEqual(d.string(forKey: Store.recordKey), "\(Store.currentVersion):declined")
    }

    // MARK: - Legacy migration (fail-closed)

    /// The torn shape the old decline left behind: the new version written, the state not yet.
    func testTheTornLegacyPairVersionTwoWithAcceptedIsNotAGrant() async throws {
        let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
        seedLegacy(d, state: CloudVoiceConsentState.accepted.rawValue, version: Store.currentVersion)
        let store = Store(defaults: d)
        XCTAssertEqual(store.state, .undecided, "ambiguous provenance is asked again")
        XCTAssertEqual(store.scope, .noLines)
        XCTAssertFalse(store.isGranted)
        let paid = await store.hasPaidVoiceConsent()
        XCTAssertFalse(paid)
        XCTAssertTrue(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: true, state: store.state))
        let calls = await cloudCalls(store)
        XCTAssertTrue(calls.isEmpty, "a legacy pair sent \(calls)")
        let tester = await TesterVoiceConsentReader(store).hasPaidVoiceConsent()
        XCTAssertFalse(tester, "the tester route reads the same record")
        // Explicit current-copy acceptance is the only way back to a grant.
        store.accept()
        XCTAssertEqual(store.scope, .allLines)
    }

    func testEveryLegacyAcceptanceReadsUndecidedAndEveryLegacyDeclineIsKept() async throws {
        let cases: [(String?, Int?, CloudVoiceConsentState)] = [
            ("accepted", 1, .undecided), ("accepted", 2, .undecided), ("accepted", 3, .undecided),
            ("accepted", nil, .undecided), ("accepted", 0, .undecided),
            ("declined", 1, .declined), ("declined", 2, .declined), ("declined", nil, .declined),
            ("undecided", 2, .undecided), (nil, 2, .undecided), (nil, 1, .undecided),
            ("ACCEPTED", 2, .undecided), ("accepted ", 2, .undecided), ("", 2, .undecided),
        ]
        for (state, version, expected) in cases {
            let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
            seedLegacy(d, state: state, version: version)
            let store = Store(defaults: d)
            XCTAssertEqual(store.state, expected, "legacy state=\(state ?? "nil") version=\(version.map(String.init) ?? "nil")")
            XCTAssertEqual(store.scope, .noLines)
            let calls = await cloudCalls(store)
            XCTAssertTrue(calls.isEmpty, "legacy \(state ?? "nil")/\(version.map(String.init) ?? "nil") sent \(calls)")
        }
    }

    func testAWriteReplacesTheLegacyKeysAndTheRecordWins() throws {
        let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
        seedLegacy(d, state: CloudVoiceConsentState.declined.rawValue, version: 1)
        let store = Store(defaults: d)
        XCTAssertEqual(store.state, .declined)
        store.accept()
        XCTAssertEqual(store.state, .accepted)
        XCTAssertNil(d.object(forKey: Store.stateKey))
        XCTAssertNil(d.object(forKey: Store.versionKey))
        // A stale legacy pair written back (e.g. by an old build) cannot override the record.
        seedLegacy(d, state: CloudVoiceConsentState.accepted.rawValue, version: Store.currentVersion)
        store.decline()
        seedLegacy(d, state: CloudVoiceConsentState.accepted.rawValue, version: Store.currentVersion)
        XCTAssertEqual(store.state, .declined)
        XCTAssertEqual(store.scope, .noLines)
    }

    // MARK: - Partial and malformed records

    func testPartialMalformedAndOtherVersionRecordsAreNotGranted() async throws {
        let records: [Any] = [
            "", ":", "2", "2:", ":accepted", "accepted", "2:accepted:x", "2:accepted:", " 2:accepted",
            "2 :accepted", "02:accepted", "+2:accepted", "-2:accepted", "1:accepted", "3:accepted",
            "999999999999999999999:accepted", "2:Accepted", "2:accepte", "2:undecided", "x:accepted",
            2, true, Data("2:accepted".utf8), ["2", "accepted"],
        ]
        for record in records {
            let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
            // Even with a legacy grant-shaped pair beside it, a bad record reads as not granted.
            seedLegacy(d, state: CloudVoiceConsentState.accepted.rawValue, version: Store.currentVersion)
            d.set(record, forKey: Store.recordKey)
            let store = Store(defaults: d)
            XCTAssertNotEqual(store.state, .accepted, "record \(record) read as accepted")
            XCTAssertEqual(store.scope, .noLines, "record \(record)")
            let calls = await cloudCalls(store)
            XCTAssertTrue(calls.isEmpty, "record \(record) sent \(calls)")
        }
        XCTAssertEqual(Store.decode("1:declined"), .declined, "a decline of any version is kept")
        XCTAssertEqual(Store.decode("\(Store.currentVersion):accepted"), .accepted)
        XCTAssertEqual(Store.decode(nil), .undecided)
    }

    // MARK: - Interleaved writes and concurrent reads

    /// Accepts and declines through two copies of the store; right after every persisted mutation,
    /// the scope must match the last record written, never a mix of two writes.
    func testInterleavedWritesAreAlwaysReadAsTheLastWholeRecord() throws {
        let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
        seedLegacy(d, state: CloudVoiceConsentState.accepted.rawValue, version: 1)
        let a = Store(defaults: d), b = Store(defaults: d)
        var lastRecord: String?
        var checked = 0
        d.observer = { key in
            if key == Store.recordKey { lastRecord = d.string(forKey: Store.recordKey) }
            let expected: CloudVoiceScope = lastRecord == "\(Store.currentVersion):accepted" ? .allLines : .noLines
            XCTAssertEqual(a.scope, expected, "after \(key) with record \(lastRecord ?? "nil")")
            XCTAssertEqual(b.scope, expected)
            checked += 1
        }
        for step in 0..<40 {
            let store = step.isMultiple(of: 2) ? a : b
            step % 3 == 0 ? store.decline() : store.accept()
        }
        d.observer = nil
        XCTAssertGreaterThanOrEqual(checked, 40)
    }

    func testConcurrentReadsDuringAVersionOneToVersionTwoDeclineNeverSeeAllLines() throws {
        for _ in 0..<25 {
            let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
            seedLegacy(d, state: CloudVoiceConsentState.accepted.rawValue, version: 1)
            let store = Store(defaults: d)
            let granted = ManagedAtomicFlag()
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                if i == 0 { store.decline(); return }
                for _ in 0..<200 where store.scope == .allLines || store.isGranted { granted.set() }
            }
            XCTAssertFalse(granted.value, "a concurrent reader saw a grant during the decline")
            XCTAssertEqual(store.state, .declined)
        }
    }

    func testFreshVersionTwoAcceptAndDecline() async throws {
        let (d, name) = try suite(); defer { d.removePersistentDomain(forName: name) }
        let store = Store(defaults: d)
        XCTAssertEqual(store.state, .undecided)
        var calls = await cloudCalls(store)
        XCTAssertTrue(calls.isEmpty, "undecided sent \(calls)")
        store.accept()
        XCTAssertEqual(d.string(forKey: Store.recordKey), "\(Store.currentVersion):accepted")
        XCTAssertEqual(Store(defaults: d).scope, .allLines, "persists across launches")
        calls = await cloudCalls(store)
        XCTAssertEqual(calls.count, 2, "v2 accepted sends every attributed line")
        store.decline()
        XCTAssertEqual(Store(defaults: d).state, .declined)
        XCTAssertFalse(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: true, state: store.state))
        calls = await cloudCalls(store)
        XCTAssertTrue(calls.isEmpty, "declined sent \(calls)")
    }

    func testTheInMemoryStoreUsesTheSameRecord() {
        let store = Store.inMemory(.accepted)
        XCTAssertEqual(store.scope, .allLines)
        store.decline()
        XCTAssertEqual(store.state, .declined)
        XCTAssertEqual(Store.inMemory().state, .undecided)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
