import XCTest
@testable import AeroDJCore

/// A snapshot whose `pending` holds a privacy reduction (it skips `init` when decoded) must
/// apply it on load, not at the first song boundary, where it would cancel break 0.
@MainActor
final class PersistedPendingReductionTests: XCTestCase {
    private func load(_ state: StationConfigurationState) async
        -> (StationConfigurationModel, InMemoryStationConfigurationStore) {
        let store = InMemoryStationConfigurationStore(snapshot: .init(state: state))
        let model = StationConfigurationModel(store: store, consent: StaticIntegrationConsent([:]))
        await model.load()
        return (model, store)
    }

    func testPersistedBriefingOffAppliesOnLoad() async throws {
        let on = StationConfiguration(briefing: .init(enabled: true))
        let off = StationConfiguration(briefing: .init(enabled: false))
        let (model, store) = await load(.init(active: on, pending: off))
        XCTAssertFalse(model.active.briefing.enabled)
        XCTAssertFalse(model.hasPendingChanges)
        let loaded = try await store.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertFalse(saved.state.active.briefing.enabled, "the promotion is persisted")
        // Nothing is left for the first song boundary to promote.
        var state = saved.state
        XCTAssertNil(state.apply(.songBoundary(afterTrack: 0)))
    }

    func testPersistedWithdrawalAppliesOnLoadAndKeepsNonReductionsPending() async {
        let active = StationConfiguration(energy: 0.4, requestedIntegrations: [.calendar])
        let pending = StationConfiguration(energy: 0.9, requestedIntegrations: [])
        let (model, _) = await load(.init(active: active, pending: pending))
        XCTAssertFalse(model.active.requestedIntegrations.contains(.calendar))
        XCTAssertEqual(model.active.energy, 0.4, "music settings still wait for the boundary")
        XCTAssertEqual(model.displayed.energy, 0.9)
        XCTAssertEqual(model.status(for: .energy), .pendingBoundary(.nextSongBoundary))
    }

    func testPersistedCommentaryOffAppliesOnLoad() async {
        let (model, _) = await load(.init(active: .init(commentary: .frequent),
                                          pending: .init(commentary: .off)))
        XCTAssertEqual(model.active.commentary, .off)
    }

    func testOrdinaryPendingIsUntouched() {
        var state = StationConfigurationState.samplePendingEdit
        let before = state
        XCTAssertNil(state.promotePendingReductions())
        XCTAssertEqual(state, before)
    }
}
