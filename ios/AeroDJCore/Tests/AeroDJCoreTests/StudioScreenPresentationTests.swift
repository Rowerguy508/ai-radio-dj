import XCTest
@testable import AeroDJCore

/// Binding rules the Studio UI (#60 takeover) renders. Pure functions over the one
/// `StudioPresentationModel` and `PlaybackSnapshot`, so they run on Linux too.
final class StudioScreenPresentationTests: XCTestCase {

    // MARK: Layout (#60 review P1: breakpoint must include edge insets)

    func testBreakpointIncludesEdgeInsets() {
        XCTAssertEqual(StudioLayoutMetrics.studioMinWidth, 716)
    }

    func testLayoutSwitchAtBoundaryWidths() {
        let cases: [(Double, StudioLayoutMode)] = [
            (683, .compact), (684, .compact), (715, .compact), (716, .studio), (800, .studio), (1024, .studio),
        ]
        for (width, want) in cases {
            XCTAssertEqual(StudioLayoutMode.resolve(containerWidth: width, accessibilityTextSize: false), want, "width \(width)")
        }
        XCTAssertEqual(StudioLayoutMode.resolve(containerWidth: 716, accessibilityTextSize: true), .studioStacked)
        XCTAssertEqual(StudioLayoutMode.resolve(containerWidth: 715, accessibilityTextSize: true), .compact)
    }

    func testZonesNeverBelowMinimumAndFillContainer() {
        XCTAssertNil(StudioZoneWidths.allocate(containerWidth: 715))
        for width in stride(from: 716.0, through: 1400, by: 1) {
            let z = StudioZoneWidths.allocate(containerWidth: width)!
            XCTAssertGreaterThanOrEqual(z.zoneA, StudioLayoutMetrics.zoneAMinWidth, "width \(width)")
            XCTAssertGreaterThanOrEqual(z.zoneB, StudioLayoutMetrics.zoneBMinWidth, "width \(width)")
            XCTAssertEqual(z.zoneA + z.zoneB + StudioLayoutMetrics.gutter + 2 * StudioLayoutMetrics.edgeInset, width, accuracy: 0.001)
        }
        // Even split once both minimums allow it: the gutter is centred on the hinge.
        let even = StudioZoneWidths.allocate(containerWidth: 900)!
        XCTAssertEqual(even.zoneA, even.zoneB)
        let exact = StudioZoneWidths.allocate(containerWidth: 716)!
        XCTAssertEqual(exact, StudioZoneWidths(zoneA: 320, zoneB: 340))
    }

    func testArtworkUsesZoneWidthAndHeightBudget() {
        let narrow = StudioZoneWidths.allocate(containerWidth: 716)!
        XCTAssertEqual(narrow.artworkSide(containerHeight: 900), 304) // 320 - 16
        let wide = StudioZoneWidths.allocate(containerWidth: 1200)!
        XCTAssertEqual(wide.artworkSide(containerHeight: 1000), 360)
        XCTAssertEqual(wide.artworkSide(containerHeight: 600), 264) // 0.44 * 600
        XCTAssertEqual(wide.artworkSide(containerHeight: 479), 120) // low height keeps transport
    }

    // MARK: Now Playing gate

    func testTransportOnlyWithAControllableTrack() {
        let playing = PlaybackFixtures.playing
        XCTAssertEqual(NowPlayingContent.resolve(access: .checking, snapshot: playing), .connecting)
        XCTAssertEqual(NowPlayingContent.resolve(access: .needsAuthorization, snapshot: playing), .needsAuthorization)
        XCTAssertEqual(NowPlayingContent.resolve(access: .denied, snapshot: playing), .accessDenied)
        XCTAssertEqual(NowPlayingContent.resolve(access: .subscriptionRequired, snapshot: playing), .subscriptionRequired)
        XCTAssertEqual(NowPlayingContent.resolve(access: .authorized, snapshot: PlaybackFixtures.stopped), .nothingPlaying)
        XCTAssertEqual(NowPlayingContent.resolve(access: .authorized, snapshot: playing), .track(PlaybackFixtures.songs[0]))
        for c in [NowPlayingContent.connecting, .needsAuthorization, .accessDenied, .subscriptionRequired, .nothingPlaying] {
            XCTAssertFalse(c.showsTransport, "\(c)")
        }
        XCTAssertTrue(NowPlayingContent.track(PlaybackFixtures.songs[0]).showsTransport)
    }

    // MARK: Errors (#60 review P1: no dead CTA; recoverable retry resumes)

    func testErrorBannerActionsAreReal() {
        func p(_ k: PlaybackError.Kind, _ r: Bool) -> PlaybackErrorPresentation {
            PlaybackErrorPresentation(PlaybackError(kind: k, message: "m", isRecoverable: r))!
        }
        XCTAssertNil(PlaybackErrorPresentation(nil))
        XCTAssertEqual(p(.notAuthorized, false).primary, .requestAuthorization)
        XCTAssertEqual(p(.notAuthorized, false).primaryTitle, "Allow")
        XCTAssertNil(p(.subscriptionRequired, false).primary)
        XCTAssertFalse(p(.subscriptionRequired, false).dismissible)
        XCTAssertEqual(p(.playbackFailed, true).primary, .retry)
        XCTAssertNil(p(.playbackFailed, false).primary)
        XCTAssertTrue(p(.playbackFailed, false).dismissible)
        XCTAssertEqual(p(.resumeFailed, true).primary, .retry)
        let speech = p(.speechFailed, true)
        XCTAssertEqual(speech.style, .caption)
        XCTAssertNil(speech.primary)
    }

    // MARK: DJ status: On Air only when the player confirmed audio

    func testOnAirOnlyWhileSpeaking() {
        let all: [DJStudioState] = [
            .idle, .preparing(includesBriefing: false), .preparing(includesBriefing: true),
            .ready(includesBriefing: false, seconds: 8), .ready(includesBriefing: true, seconds: 40),
            .speaking(includesBriefing: false), .speaking(includesBriefing: true),
            .failed(.voiceFailed), .failed(.budgetReached), .failed(.consentReviewRequired(pendingCount: 2)),
        ]
        for s in all {
            let p = DJStatusPresentation(state: s)
            if case .speaking = s {
                XCTAssertEqual(p.onAirBadge, "On Air")
                XCTAssertTrue(p.animatesActivity)
            } else {
                XCTAssertNil(p.onAirBadge, "\(s)")
                XCTAssertFalse(p.animatesActivity, "\(s)")
                XCTAssertFalse(p.accessibilityLabel.contains("On Air"), "\(s)")
            }
        }
    }

    func testIdleSaysNothingAndReviewIsActionable() {
        let idle = DJStatusPresentation(state: .idle)
        XCTAssertNil(idle.headline)
        XCTAssertEqual(idle.accessibilityLabel, "")
        let review = DJStatusPresentation(state: .failed(.consentReviewRequired(pendingCount: 3)))
        XCTAssertEqual(review.reviewCount, 3)
        XCTAssertEqual(review.headline, "3 to review")
        let speakingNoLine = DJStatusPresentation(state: .speaking(includesBriefing: false))
        XCTAssertEqual(speakingNoLine.onAirBadge, "On Air")
    }

    @MainActor
    func testDJStatusFollowsTheRealReducer() {
        let store = DJPresentationStore()
        store.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 9))
        XCTAssertNil(DJStatusPresentation(state: store.studioState).onAirBadge)
        store.send(.playbackStarted(afterTrack: 0))
        XCTAssertEqual(DJStatusPresentation(state: store.studioState).onAirBadge, "On Air")
        store.send(.playbackFailed(afterTrack: 0))
        XCTAssertNil(DJStatusPresentation(state: store.studioState).onAirBadge)
    }

    // MARK: Connections: every offered action has a real route

    func testEveryOfferedSourceActionRoutesSomewhere() {
        let caps = ConnectionUICapabilities.current
        let calendars: [CalendarConnectionState] = [
            .init(access: .notDetermined), .init(access: .denied), .init(access: .restricted), .init(access: .writeOnly),
            .init(access: .fullAccess, calendars: [.init(id: "w", title: "Work")]),
            .init(access: .fullAccess, calendars: [.init(id: "w", title: "Work")], selectedCalendarIDs: ["w"]),
        ]
        for c in calendars {
            for a in c.actions {
                if case .unavailable = caps.route(a, onSource: .calendar) { XCTFail("calendar \(a) must be actionable") }
            }
        }
        XCTAssertEqual(caps.route(.reselect, onSource: .calendar), .calendarPicker)
        XCTAssertEqual(caps.route(.openSettings, onSource: .calendar), .systemSettings)
        XCTAssertEqual(caps.route(.allowAccess, onSource: .calendar), .model)
        XCTAssertEqual(caps.route(.revoke, onSource: .obsidian), .model)
        // No bookmark store yet: choosing notes is explained, not a dead button.
        XCTAssertEqual(caps.route(.reselect, onSource: .obsidian), .unavailable(ConnectionUICapabilities.obsidianPickerUnavailable))
        XCTAssertEqual(ConnectionUICapabilities(canPickObsidianFiles: true).route(.reselect, onSource: .obsidian), .filePicker)
    }

    @MainActor
    func testConnectedBadgeOnlyWhenReadable() async {
        let station = await StationConfigurationModel.preview(consent: [.calendar: .granted, .shareInbox: .granted, .obsidian: .granted])
        await station.setIntegration(.calendar, requested: true)
        await station.setIntegration(.obsidian, requested: true)
        let reader = StaticConnectionSourceReader(
            calendar: .init(access: .fullAccess, calendars: [.init(id: "w", title: "Work")], selectedCalendarIDs: []),
            obsidian: .stale)
        let model = ConnectionsModel(station: station, sourceReader: reader, providers: [], purger: NoopNarrationPurger())
        await model.refresh()
        for row in model.sources {
            XCTAssertNotEqual(row.badge, "Connected", "\(row.integration) is requested but not readable")
        }
        _ = await model.selectCalendars(["w"])
        XCTAssertEqual(model.source(.calendar).badge, "Connected")
        // Stop using: purges, clears selection, badge drops immediately.
        _ = await model.perform(.revoke, onSource: .calendar)
        XCTAssertNotEqual(model.source(.calendar).badge, "Connected")
    }

    // MARK: Tuner copy

    @MainActor
    func testPendingRowSaysAppliesAfterThisSongAndWhatIsActive() async {
        let station = await StationConfigurationModel.preview()
        await station.setPlaybackActivity(.holdingSong)
        let before = station.tunerRow(for: .energy).activeSummary
        await station.setEnergy(0.95)
        await station.saveChanges()
        let row = station.tunerRow(for: .energy)
        XCTAssertEqual(row.appliesCopy, "Applies after this song")
        XCTAssertEqual(row.activeSummary, before, "the playing song keeps the active value")
        XCTAssertTrue(row.accessibilitySummary.contains("Applies after this song"))
        XCTAssertTrue(row.accessibilitySummary.contains("Now using: \(before)"))
    }
}

final class TunerIndicatorTests: XCTestCase {
    func testSettingsNothingReadsSaySavedNeverActive() {
        for s in [StationSetting.genres, .moods, .energy, .discovery] {
            XCTAssertEqual(TunerIndicator(status: .idle, setting: s), .saved)
            XCTAssertNotEqual(TunerIndicator(status: .idle, setting: s).label, "Active")
        }
    }

    func testReadSettingsAreActive() {
        for s in [StationSetting.commentary, .personality, .briefing, .integration(.calendar)] {
            XCTAssertEqual(TunerIndicator(status: .idle, setting: s), .active)
        }
    }

    func testPendingCarriesBoundaryCopy() {
        let i = TunerIndicator(status: .pendingBoundary(.nextSongBoundary), setting: .energy)
        XCTAssertEqual(i, .pending("Applies after this song"))
        XCTAssertEqual(i.label, "Pending")
        XCTAssertTrue(i.accessibilityLabel.contains("after this song"))
    }

    func testConsentAndErrors() {
        XCTAssertEqual(TunerIndicator(status: .consentRequired(.notRequested), setting: .integration(.obsidian)),
                       .needsConsent("Needs permission"))
        XCTAssertEqual(TunerIndicator(status: .consentRequired(.revoked), setting: .integration(.calendar)).label, "Revoked")
        XCTAssertEqual(TunerIndicator(status: .error(.saveFailed), setting: .moods), .problem("Couldn't save"))
        XCTAssertEqual(TunerIndicator(status: .saving, setting: .moods), .saving)
    }

    func testUsageCopyNeverClaimsSongPicking() {
        for s in [StationSetting.genres, .moods, .energy, .discovery] {
            XCTAssertTrue(s.usageCopy.contains("Not used for song picking"))
        }
    }
}
