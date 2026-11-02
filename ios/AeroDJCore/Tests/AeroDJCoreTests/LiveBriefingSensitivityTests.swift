import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AeroDJCore

// Nigel's report (relayed by Orion): the live `StudioPresentationModel.liveQueueBriefing` passed
// an empty `sensitivityByItemID`, and a missing id is `.blocked`, so the live briefing was silent.
// These tests run the path exactly as the app wires it: a real `ConnectionsModel` inside a real
// `StudioPresentationModel`, read through `LiveQueueBriefing.provider(studio:)`.
// Fixture titles only; assertion messages print counts and ids, never cue text.

private struct FixtureProvider: ConnectionItemProvider {
    let integration: StationIntegration
    let list: [ConnectionItem]
    func items(now: Date) async throws -> [ConnectionItem] { list }
    func perform(_ action: ConnectionAction, on id: UUID) async throws {}
}

private struct NoPurge: NarrationPurging {
    func purge(sourceItemIDs: Set<UUID>) async {}
}

@MainActor
class LiveBriefingFixture: XCTestCase {
    let utcZone = TimeZone(identifier: "UTC")!

    func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    func at(_ zone: TimeZone, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// 08:00 UTC on a fixed day.
    var eight: Date { at(utcZone, 2026, 10, 26, 8) }

    func liveStudio(_ items: [ConnectionItem]) async -> StudioPresentationModel {
        var config = StationConfiguration.sampleMorningMix
        config.briefing = BriefingPreferences(enabled: true, window: BriefingWindow(startMinute: 7 * 60, durationMinutes: 120),
                                              sections: Set(BriefingSection.allCases))
        config.requestedIntegrations = Set(StationIntegration.allCases)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([.calendar: .granted, .shareInbox: .granted, .obsidian: .granted]))
        await station.load()
        let providers: [any ConnectionItemProvider] = StationIntegration.allCases.map { integration in
            FixtureProvider(integration: integration, list: items.filter { $0.integration == integration })
        }
        let refreshAt = eight
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(),
                                           providers: providers, purger: NoPurge(), now: { refreshAt })
        let studio = StudioPresentationModel(station: station, recipes: StationRecipeLibrary(store: InMemoryStationRecipeStore()),
                                             connections: connections, dj: DJPresentationStore())
        await studio.connections.refresh()
        return studio
    }

    func contentIDs(_ handoff: NarrationHandoff?) -> [UUID] {
        (handoff?.cues ?? []).filter(\.isContent).compactMap(\.sourceItemID)
    }

    /// The live provider at 08:00 UTC with a fresh #332 ledger: what the app would queue.
    func liveQueued(_ studio: StudioPresentationModel) -> NarrationHandoff? {
        let now = eight
        return LiveQueueBriefing.provider(studio: studio, now: { now }, calendar: calendar(utcZone),
                                          ledger: PersonalUpdateLedger())().forQueue()
    }
}

final class LiveBriefingSensitivityTests: LiveBriefingFixture {
    /// Red on ec26f89 (0 of 2 content cues): the live input carried `[:]`, so both rows were blocked.
    func testLiveStudioBriefingSpeaksUnblockedCalendarAndSharedItems() async throws {
        let event = UUID(), reminder = UUID()
        let studio = await liveStudio([
            ConnectionItem(id: event, integration: .calendar, title: "Fixture standup", state: .approved, sensitivity: .low),
            ConnectionItem(id: reminder, integration: .shareInbox, title: "Fixture reminder", state: .approved, sensitivity: .medium),
        ])
        let spoken = Set(contentIDs(liveQueued(studio)))
        XCTAssertEqual(spoken, [event, reminder],
                       "unblocked approved rows are spoken (\(spoken.count) of 2 content cues)")
    }

    /// One builder: the live briefing input is exactly the map `ConnectionsModel` builds,
    /// which is `ConnectionItem.sensitivityMap` of its rows. Fails if either side drifts.
    func testLiveBriefingMapIsTheConnectionsModelMap() async throws {
        let ids = (0..<6).map { _ in UUID() }
        let studio = await liveStudio([
            ConnectionItem(id: ids[0], integration: .calendar, title: "Fixture a", state: .approved, sensitivity: .low),
            ConnectionItem(id: ids[1], integration: .calendar, title: "Fixture b", state: .approved, sensitivity: .high),
            ConnectionItem(id: ids[2], integration: .shareInbox, title: "Fixture c", state: .pendingApproval, sensitivity: .medium),
            ConnectionItem(id: ids[3], integration: .obsidian, title: "Fixture d", state: .unavailable(.markedPrivate), sensitivity: .blocked),
            ConnectionItem(id: ids[4], integration: .obsidian, title: "Fixture e", state: .approved, sensitivity: nil),
            ConnectionItem(id: ids[5], integration: .shareInbox, title: "Fixture f", state: .revoked, sensitivity: .low),
        ])
        let live = studio.liveQueueBriefing.sensitivityByItemID
        XCTAssertEqual(live, studio.connections.sensitivityByItemID)
        XCTAssertEqual(live, ConnectionItem.sensitivityMap(studio.connections.items))
        XCTAssertEqual(live.count, 5, "every row with a sensitivity, none invented")
        XCTAssertNil(live[ids[4]], "no sensitivity: left out, never defaulted")
        XCTAssertEqual(live[ids[1]], .high)
        XCTAssertEqual(live[ids[3]], .blocked)
        XCTAssertEqual(studio.liveQueueBriefing.items, studio.connections.items)
    }

    // MARK: Sentinel gate 1: a row missing from the map defaults to blocked

    func testRowMissingFromTheMapStaysBlockedOnTheLivePath() async throws {
        let control = UUID(), unknown = UUID()
        let studio = await liveStudio([
            ConnectionItem(id: control, integration: .calendar, title: "Fixture standup", state: .approved, sensitivity: .low),
            ConnectionItem(id: unknown, integration: .obsidian, title: "Fixture unclassified", state: .approved, sensitivity: nil),
        ])
        XCTAssertNil(studio.liveQueueBriefing.sensitivityByItemID[unknown])
        let spoken = contentIDs(liveQueued(studio))
        XCTAssertEqual(spoken, [control], "only the classified row (\(spoken.count) content cues)")
    }

    // MARK: Sentinel gate 2: blocked, revoked and expired rows stay silent

    /// Gate 2, row layer pinned on its own: the consent mapping alone would still silence a
    /// revoked or expired row, so without this a row-layer regression would hide behind it.
    func testOnlyApprovedRowsMayBeNarrated() {
        XCTAssertTrue(ConnectionItemState.approved.mayBeNarrated)
        for state: ConnectionItemState in [.revoked, .expired, .pendingApproval, .flaggedForReview] {
            XCTAssertFalse(state.mayBeNarrated, "\(state) must stay silent")
        }
    }

    func testBlockedRevokedAndExpiredRowsStaySilentOnTheLivePath() async throws {
        let control = UUID(), blocked = UUID(), revoked = UUID(), expired = UUID(), lapsed = UUID()
        let studio = await liveStudio([
            ConnectionItem(id: control, integration: .calendar, title: "Fixture standup", state: .approved, sensitivity: .low),
            // Approved row whose source is marked blocked (sensitivity outranks approval).
            ConnectionItem(id: blocked, integration: .obsidian, title: "Fixture private", state: .approved, sensitivity: .blocked),
            ConnectionItem(id: revoked, integration: .shareInbox, title: "Fixture revoked", state: .revoked, sensitivity: .low),
            ConnectionItem(id: expired, integration: .calendar, title: "Fixture expired", state: .expired, sensitivity: .low),
            // Still `.approved` from the last refresh, but its expiry has passed by play time.
            ConnectionItem(id: lapsed, integration: .calendar, title: "Fixture lapsed", state: .approved,
                           expiresAt: eight.addingTimeInterval(-60), sensitivity: .low),
        ])
        let spoken = contentIDs(liveQueued(studio))
        XCTAssertEqual(spoken, [control], "only the control row (\(spoken.count) content cues)")
        for silent in [blocked, revoked, expired, lapsed] { XCTAssertFalse(spoken.contains(silent), "\(silent)") }
    }

    // MARK: Sentinel gate 3: calendar, share and notes cues stay on-device with cloud voice on

    private struct BodyRecorder: HTTPTransport {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var bodies: [Data] = []
        }
        let box = Box()
        var bodies: [Data] { box.lock.withLock { box.bodies } }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            box.lock.withLock { box.bodies.append(request.httpBody ?? Data()) }
            let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "1.0", "X-Billed-Characters": "20"]
            return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
        }
    }

    private struct DeviceVoice: VoiceProvider {
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            VoiceArtifact(data: Data("d".utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
        }
    }

    func testBriefingCuesFromCalendarShareAndNotesRenderOnDeviceWithCloudVoiceOn() async throws {
        let event = UUID(), shared = UUID(), note = UUID()
        let titles = ["Fixture standup", "Fixture reminder", "Fixture grocery"]
        let studio = await liveStudio([
            ConnectionItem(id: event, integration: .calendar, title: titles[0], state: .approved, sensitivity: .low),
            ConnectionItem(id: shared, integration: .shareInbox, title: titles[1], state: .approved, sensitivity: .medium),
            ConnectionItem(id: note, integration: .obsidian, title: titles[2], state: .approved, sensitivity: .medium),
        ])
        let handoff = try XCTUnwrap(liveQueued(studio))
        XCTAssertEqual(Set(contentIDs(handoff)), [event, shared, note])

        // Cloud voice on: every gate of `PremiumVoiceRoutes.compose` passes, ElevenLabs is first.
        // A current catalog voice, not a fixed id (f601577 retired the old lineup).
        let transport = BodyRecorder()
        let device = VoiceRoute(providerID: "avspeech", provider: DeviceVoice(), voice: VoiceProfile(id: "standard", name: "Host"))
        let composed = PremiumVoiceRoutes.compose(
            onDevice: [device], paidProvidersEnabled: true, selectedVoiceID: PremiumVoiceCatalog.voices[0].id,
            credentials: PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "fixture-token"),
            pinnedHosts: ["aerodj-tts.vercel.app"], transport: transport)
        guard case .included = composed.decision else { return XCTFail("cloud voice must be on for this gate") }
        let renderer = VoiceRenderer(routes: composed.routes, budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache(), revocations: NarrationRevocations())

        let tracks = djTracks(8, origin: .catalog)
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 2, stationName: "OnAirly")
        let plan = writer.plan(tracks: tracks, briefing: handoff, hour: 14)
        let briefingBreaks = plan.breaks.filter(\.hasBriefing)
        XCTAssertEqual(Set(briefingBreaks.flatMap(\.cues).filter(\.isContent).compactMap(\.sourceItemID)), [event, shared, note])

        var deviceRendered: Set<UUID> = []
        for djBreak in briefingBreaks {
            let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", talkOverEnabled: { false })
            let done = AsyncStream<Void>.makeStream()
            await preparer.observe { event in
                switch event {
                case .prepared, .skipped: done.continuation.yield()
                case .preparing: break
                }
            }
            await preparer.prepare(djBreak, deadline: .seconds(5), onDeviceOnly: false)
            for await _ in done.stream { break }
            guard case .ready(let ready) = await preparer.takeBreak(afterTrack: djBreak.afterTrack) else {
                return XCTFail("the briefing break renders on the device voice")
            }
            for cue in djBreak.cues where cue.isContent {
                let clip = try XCTUnwrap(ready.clips.first { $0.cueID == cue.id })
                XCTAssertEqual(clip.audio.providerID, "avspeech", "briefing cue \(cue.source.map { "\($0)" } ?? "?") stays on-device")
                if let id = cue.sourceItemID { deviceRendered.insert(id) }
            }
        }
        XCTAssertEqual(deviceRendered, [event, shared, note])
        let sent = transport.bodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertFalse(sent.isEmpty, "the cloud route is live: catalog lines in the same breaks used it")
        for title in titles {
            XCTAssertFalse(sent.contains { $0.contains(title) }, "no personal text reached the cloud route")
        }
    }
}
