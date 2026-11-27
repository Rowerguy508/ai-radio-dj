import Foundation
import XCTest
@testable import AeroDJCore

/// #302 (-Atlas): an announced next song that fails to start must not leave music stopped.
/// 1. Before handing out a break, an unplayable `tracks[k + 1]` (`song == nil`) drops its intro
///    cues the same way a stale "up next" does.
/// 2. In `startNextTrack`, one failure advances once to `k + 2` without a new intro; two failures
///    (or no `k + 2`) stop and show the failure banner.
final class NextSongStartFailureAdvanceTests: XCTestCase {

    private func cue(_ text: String, order: Int = 0) -> NarrationCue {
        NarrationCue(
            id: UUID(), order: order, group: -1, kind: .transition, text: text,
            estimatedSeconds: 2, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil
        )
    }

    private func clip(_ cue: NarrationCue, seconds: Double = 1.5) -> RenderedClip {
        RenderedClip(
            cueID: cue.id,
            audio: CachedAudio(data: Data([1, 2]), seconds: seconds, providerID: "device", voiceID: "v"),
            cacheKey: "k-\(cue.id.uuidString)",
            attempts: []
        )
    }

    private func tracks(_ count: Int) -> [TrackInfo] {
        (0..<count).map { TrackInfo(id: "t\($0)", title: "Song \($0)", artistName: "Artist \($0)") }
    }

    // MARK: - Unplayable next song intro drop

    func testUnplayableNextSongDropsIntroOnlyBreak() {
        let intro = cue("Up next, Song 1.")
        let prepared = PreparedDJBreak(
            afterTrack: 0,
            cues: [intro],
            clips: [clip(intro)],
            attributions: [intro.id: .trackMetadata(trackIDs: ["t1"])],
            talkOverCueID: intro.id
        )

        XCTAssertNil(BreakHandoffPolicy.filteringUnplayableNext(prepared, unplayableNextTrackID: "t1"))
        XCTAssertEqual(
            BreakHandoffPolicy.decide(prepared: prepared, unplayableNextTrackID: "t1"),
            .continueMusic,
            "an intro-only break for an unplayable next song must be skipped"
        )
    }

    func testUnplayableNextSongDropsOnlyIntroAndKeepsOutroAndPresenterLines() {
        let outro = cue("That was Song 0.", order: 0)
        let presenter = cue("Stay right where you are.", order: 1)
        let intro = cue("Up next, Song 1.", order: 2)
        let prepared = PreparedDJBreak(
            afterTrack: 0,
            cues: [outro, presenter, intro],
            clips: [clip(outro), clip(presenter), clip(intro)],
            attributions: [
                outro.id: .trackMetadata(trackIDs: ["t0"]),
                presenter.id: .presenter,
                intro.id: .trackMetadata(trackIDs: ["t1"]),
            ],
            talkOverCueID: intro.id
        )

        let decision = BreakHandoffPolicy.decide(prepared: prepared, unplayableNextTrackID: "t1")
        guard case .play(let narrowed) = decision else {
            return XCTFail("expected outro and presenter cues to survive, got \(decision)")
        }
        XCTAssertEqual(narrowed.cues.map(\.id), [outro.id, presenter.id])
        XCTAssertEqual(narrowed.clips.map(\.cueID), [outro.id, presenter.id])
        XCTAssertNil(narrowed.attributions[intro.id])
        XCTAssertNil(narrowed.talkOverCueID, "talk-over closing cue was dropped with the intro")
    }

    func testPlayableNextSongKeepsIntroUntouched() {
        let intro = cue("Up next, Song 1.")
        let prepared = PreparedDJBreak(
            afterTrack: 0,
            cues: [intro],
            clips: [clip(intro)],
            attributions: [intro.id: .trackMetadata(trackIDs: ["t1"])],
            talkOverCueID: intro.id
        )

        XCTAssertEqual(
            BreakHandoffPolicy.decide(prepared: prepared, unplayableNextTrackID: nil),
            .play(prepared)
        )
    }

    // MARK: - NextSongStartFailure recovery policy

    func testFirstFailureAdvancesOnceToKPlus2() {
        let code = PlaybackErrorCode(typeName: "MusicKitError", domain: "AeroDJ", code: 1)
        let recovery = NextSongStartFailure.decide(
            code: code,
            attempt: 1,
            attemptIsCurrent: true,
            failedIndex: 1,
            queueCount: 4,
            retriesUsed: 0
        )
        XCTAssertEqual(recovery, .retry(nextIndex: 2))
    }

    func testSecondFailureStopsAndShowsBannerEvenWhenMoreTracksExist() {
        let code = PlaybackErrorCode(typeName: "MPError", domain: "MPErrorDomain", code: 5)
        let recovery = NextSongStartFailure.decide(
            code: code,
            attempt: 2,
            attemptIsCurrent: true,
            failedIndex: 2,
            queueCount: 5,
            retriesUsed: 1
        )
        XCTAssertEqual(
            recovery,
            .stop(banner: "Could not start the next song: MPError MPErrorDomain code 5. attempt=2")
        )
    }

    func testFirstFailureAtEndOfQueueStopsAndShowsBanner() {
        let code = PlaybackErrorCode(typeName: "MusicKitError", domain: "AeroDJ", code: 1)
        let recovery = NextSongStartFailure.decide(
            code: code,
            attempt: 1,
            attemptIsCurrent: true,
            failedIndex: 1,
            queueCount: 2,
            retriesUsed: 0
        )
        XCTAssertEqual(
            recovery,
            .stop(banner: "Could not start the next song: MusicKitError AeroDJ code 1. attempt=1")
        )
    }

    func testSupersededAttemptIsIgnoredWithNoRetryAndNoBanner() {
        let code = PlaybackErrorCode(typeName: "MPError", domain: "MPErrorDomain", code: 5)
        let recovery = NextSongStartFailure.decide(
            code: code,
            attempt: 1,
            attemptIsCurrent: false,
            failedIndex: 1,
            queueCount: 4,
            retriesUsed: 0
        )
        XCTAssertEqual(recovery, .ignore)
    }

    // MARK: - End-to-end startNextTrack loop simulation

    private func runStartNextTrack(
        queueCount: Int,
        after finishedIndex: Int = 0,
        failingIndices: Set<Int>,
        userTapDuringAttempt: Int? = nil
    ) -> (attempted: [Int], nowPlayingID: String?, banner: String?) {
        var engine = PlaybackEngine()
        let q = tracks(queueCount)
        engine.apply(.queueStarted(tracks: q, startIndex: finishedIndex, station: nil))
        engine.apply(.playbackConfirmed)
        engine.apply(.naturalBoundary(nextIndex: finishedIndex + 1))

        var attempts = PlaybackAttempts()
        attempts.armNext(after: finishedIndex)
        guard attempts.takeNext(after: finishedIndex) else {
            return ([], engine.snapshot.nowPlaying?.id, nil)
        }

        var target = finishedIndex + 1
        var retriesUsed = 0
        let generation = attempts.queueGeneration
        var attempted: [Int] = []
        var banner: String?
        let code = PlaybackErrorCode(typeName: "MusicKitError", domain: "AeroDJ", code: 1)

        while target < queueCount {
            let attempt = attempts.beginStart()
            attempted.append(target)
            if userTapDuringAttempt == attempt.number {
                _ = attempts.userChangedQueue()
                _ = attempts.beginStart()
            }
            if failingIndices.contains(target) {
                switch NextSongStartFailure.decide(
                    code: code,
                    attempt: attempt.number,
                    attemptIsCurrent: attempts.ownsLoad(attempt: attempt, generation: generation),
                    failedIndex: target,
                    queueCount: queueCount,
                    retriesUsed: retriesUsed
                ) {
                case .ignore:
                    return (attempted, engine.snapshot.nowPlaying?.id, nil)
                case .retry(let retryIndex):
                    retriesUsed += 1
                    target = retryIndex
                    engine.apply(.naturalBoundary(nextIndex: retryIndex))
                case .stop(let message):
                    banner = message
                    return (attempted, engine.snapshot.nowPlaying?.id, banner)
                }
            } else {
                engine.apply(.playbackConfirmed)
                return (attempted, engine.snapshot.nowPlaying?.id, nil)
            }
        }
        return (attempted, engine.snapshot.nowPlaying?.id, banner)
    }

    func testOneFailureAdvancesToKPlus2WithoutBanner() {
        let result = runStartNextTrack(queueCount: 4, after: 0, failingIndices: [1])
        XCTAssertEqual(result.attempted, [1, 2])
        XCTAssertEqual(result.nowPlayingID, "t2")
        XCTAssertNil(result.banner)
    }

    func testTwoFailuresStopAndShowBannerWithoutAdvancingToKPlus3() {
        let result = runStartNextTrack(queueCount: 4, after: 0, failingIndices: [1, 2])
        XCTAssertEqual(result.attempted, [1, 2])
        XCTAssertEqual(result.nowPlayingID, "t2")
        XCTAssertEqual(
            result.banner,
            "Could not start the next song: MusicKitError AeroDJ code 1. attempt=2"
        )
    }

    func testUserTapDuringFailedStartDoesNotRetryKPlus2() {
        let result = runStartNextTrack(
            queueCount: 4, after: 0, failingIndices: [1], userTapDuringAttempt: 1
        )
        XCTAssertEqual(result.attempted, [1])
        XCTAssertNil(result.banner)
    }
}
