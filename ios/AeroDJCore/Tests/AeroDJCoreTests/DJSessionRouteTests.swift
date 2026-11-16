import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

/// #525 (-Atlas): the DJ voice follows the music to AirPlay. Pins the session for every route,
/// break kind and flag value, the remote flag, the gap-break preparation on AirPlay, the DIAG rows
/// and the app wiring. NOT device evidence: no Linux or simulator test proves real AirPlay,
/// Bluetooth or CarPlay routing; only the owner's device check can.
final class DJSessionRouteTests: XCTestCase {

    // MARK: DJSessionConfig: every combination

    func testEveryRouteKindAndFlagValueResolvesToTheExpectedSession() {
        for route in LongFormRouteKind.allCases {
            for flag in [false, true] {
                let airPlay = flag && route == .airPlay
                let gap = DJSessionConfig.resolve(route: route, kind: .gap, airPlayFlag: flag)
                let talk = DJSessionConfig.resolve(route: route, kind: .talkover, airPlayFlag: flag)
                let label = "route=\(route) flag=\(flag)"
                XCTAssertEqual(gap.category, .playback, label)
                XCTAssertEqual(gap.mode, .default, label)
                XCTAssertEqual(talk.category, .playback, label)
                XCTAssertEqual(talk.mode, .default, label)
                if airPlay {
                    XCTAssertEqual(gap.policy, .longFormAudio, label)
                    XCTAssertEqual(gap.options, [], "Apple: options only with the default policy. \(label)")
                    XCTAssertEqual(gap.shape, .longFormAirPlay, label)
                    XCTAssertFalse(gap.talkoverAllowed, label)
                    XCTAssertFalse(gap.fellBackToGap, label)
                    XCTAssertEqual(talk.policy, .longFormAudio, "talk-over falls back to the long-form gap break. \(label)")
                    XCTAssertEqual(talk.options, [], label)
                    XCTAssertEqual(talk.shape, .longFormAirPlay, label)
                    XCTAssertFalse(talk.talkoverAllowed, "no talk-over on AirPlay: a long-form session cannot duck. \(label)")
                    XCTAssertTrue(talk.fellBackToGap, label)
                } else {
                    XCTAssertEqual(gap, .normal, "today's session, unchanged. \(label)")
                    XCTAssertEqual(talk, .talkoverDuck, "today's duck, unchanged. \(label)")
                    XCTAssertTrue(talk.talkoverAllowed, label)
                    XCTAssertFalse(talk.fellBackToGap, label)
                }
            }
        }
    }

    func testTodaysSessionsArePinnedValueByValue() {
        // Normal: .playback, .default, default policy, [.mixWithOthers] (0x1), as Build 10 P0 set it.
        XCTAssertTrue(AppAudioSessionConfig.mixesWithOthers)
        XCTAssertEqual(DJSessionConfig.normal.policy, .default)
        XCTAssertEqual(DJSessionConfig.normal.options.rawValue, 0x1)
        XCTAssertEqual(DJSessionConfig.normal.shape, .mixDefault)
        XCTAssertTrue(DJSessionConfig.normal.talkoverAllowed)
        // Talk-over duck: .playback, .default, default policy, [.duckOthers] (0x2).
        XCTAssertEqual(DJSessionConfig.talkoverDuck.policy, .default)
        XCTAssertEqual(DJSessionConfig.talkoverDuck.options.rawValue, 0x2)
        XCTAssertEqual(DJSessionConfig.talkoverDuck.shape, .duckDefault)
        // AirPlay gap: .playback, .default, .longFormAudio, no options.
        XCTAssertEqual(DJSessionConfig.airPlayGap.policy, .longFormAudio)
        XCTAssertEqual(DJSessionConfig.airPlayGap.options.rawValue, 0)
        XCTAssertEqual(DJSessionConfig.airPlayGap.category, .playback)
        XCTAssertEqual(DJSessionConfig.airPlayGap.mode, .default)
    }

    // MARK: Route classification

    func testAirPlayWinsAndEachPortTypeMapsToItsRoute() {
        XCTAssertEqual(LongFormRouteKind.classify([]), .unknown)
        XCTAssertEqual(LongFormRouteKind.classify([.airPlay]), .airPlay)
        XCTAssertEqual(LongFormRouteKind.classify([.builtInSpeaker, .airPlay]), .airPlay, "a group with AirPlay is AirPlay")
        XCTAssertEqual(LongFormRouteKind.classify([.carAudio]), .carPlay)
        for p in [LongFormPortType.bluetoothA2DP, .bluetoothLE, .bluetoothHFP] { XCTAssertEqual(LongFormRouteKind.classify([p]), .bluetooth) }
        for p in [LongFormPortType.headphones, .usbAudio, .hdmi, .lineOut] { XCTAssertEqual(LongFormRouteKind.classify([p]), .wired) }
        for p in [LongFormPortType.builtInSpeaker, .builtInReceiver] { XCTAssertEqual(LongFormRouteKind.classify([p]), .builtIn) }
        XCTAssertEqual(LongFormRouteKind.classify([.other]), .other)
        // Only AirPlay changes the session; every other route keeps today's.
        for p in LongFormPortType.allCases where p != .airPlay {
            XCTAssertEqual(DJSessionConfig.resolve(route: .classify([p]), kind: .gap, airPlayFlag: true), .normal, "\(p)")
            XCTAssertEqual(DJSessionConfig.resolve(route: .classify([p]), kind: .talkover, airPlayFlag: true), .talkoverDuck, "\(p)")
        }
    }

    // MARK: Remote flag

    func testTheKillSwitchDefaultsOnAndOnlyAJSONFalseTurnsItOff() throws {
        XCTAssertTrue(DJAirPlayRouteFlag.defaultValue, "kill switch: on unless killed (Orion, Nov 14)")
        let store = DJAirPlayFlagStore()
        XCTAssertTrue(DJAirPlayRouteFlag.isEnabled(store: store), "never fetched: on")
        XCTAssertEqual(DJAirPlayRouteFlag.parse(Data(#"{"djAirPlayLongForm":true}"#.utf8)), true)
        XCTAssertEqual(DJAirPlayRouteFlag.parse(Data(#"{"djAirPlayLongForm":false}"#.utf8)), false)
        for body in [#"{"djAirPlayLongForm":0}"#, #"{"djAirPlayLongForm":"false"}"#, #"{"other":false}"#, "false", "", "not json"] {
            XCTAssertNil(DJAirPlayRouteFlag.parse(Data(body.utf8)), "\(body): unreadable, the stored value stays")
        }
        XCTAssertNil(DJAirPlayRouteFlag.parse(Data(String(repeating: " ", count: 2000).utf8)), "oversized body")
    }

    func testAFailedFetchFailsOpenAndOnlyAFetchedFalseKills() async throws {
        let base = URL(string: "https://proxy.invalid")!
        // Never fetched, then every kind of failure: still on.
        let fresh = DJAirPlayFlagStore()
        for t in [FlagTransport(status: 503, body: #"{"djAirPlayLongForm":false}"#),
                  FlagTransport(status: 200, body: "nope"), FlagTransport(error: true)] {
            let value = await DJAirPlayRouteFlag.refresh(transport: t, baseURL: base, store: fresh)
            XCTAssertTrue(value, "fail open")
        }
        XCTAssertTrue(DJAirPlayRouteFlag.isEnabled(store: fresh))
        // A fetched false kills it, and the request is a bare GET.
        let kill = FlagTransport(status: 200, body: #"{"djAirPlayLongForm":false}"#)
        let killed = await DJAirPlayRouteFlag.refresh(transport: kill, baseURL: base, store: fresh)
        XCTAssertFalse(killed)
        XCTAssertFalse(DJAirPlayRouteFlag.isEnabled(store: fresh))
        let request = try XCTUnwrap(kill.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://proxy.invalid/api/flags")
        XCTAssertNil(request.httpBody, "nothing is sent")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no token")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(DJAirPlayRouteFlag.request(baseURL: DJAirPlayRouteFlag.proxyBaseURL)?.url?.absoluteString,
                       "https://aerodj-tts.vercel.app/api/flags")
        // While killed, a failure keeps it killed; a fetched true lifts it.
        let stillKilled = await DJAirPlayRouteFlag.refresh(transport: FlagTransport(error: true), baseURL: base, store: fresh)
        XCTAssertFalse(stillKilled)
        let lifted = await DJAirPlayRouteFlag.refresh(transport: FlagTransport(status: 200, body: #"{"djAirPlayLongForm":true}"#),
                                                      baseURL: base, store: fresh)
        XCTAssertTrue(lifted)
    }

    /// Orion (Nov 14): the value lives in memory only. A fetched `false` kills it for this launch;
    /// a new launch (a new store) starts ON, and nothing is written to UserDefaults.
    @MainActor
    func testAFetchedFalseDoesNotCarryOverToANewLaunch() async throws {
        let base = URL(string: "https://proxy.invalid")!
        let launch1 = DJAirPlayFlagStore()
        let killed = await DJAirPlayRouteFlag.refresh(transport: FlagTransport(status: 200, body: #"{"djAirPlayLongForm":false}"#),
                                                      baseURL: base, store: launch1)
        XCTAssertFalse(killed)
        XCTAssertFalse(DJAirPlayRouteFlag.isEnabled(store: launch1), "killed for the rest of this launch")
        let launch2 = DJAirPlayFlagStore()
        XCTAssertTrue(launch2.value, "a new launch starts ON")
        XCTAssertTrue(DJAirPlayRouteFlag.isEnabled(store: launch2))
        // A new launch's core starts on too, and its launch probe on AirPlay refetches once.
        let s = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { launch2.value }), flag: { launch2.value })
        let probe = core.probeBeforeSong(s)
        XCTAssertEqual(probe?.fetch, true, "the next launch's first AirPlay detection refetches")
        // No persistence anywhere in the flag's code.
        for file in ["Playback/DJSessionRoute.swift", "Playback/DJRouteSessionCore.swift"] {
            let source = try coreSource(file)
            XCTAssertFalse(source.contains("UserDefaults."), file)
            XCTAssertFalse(source.contains("defaults.set"), file)
            XCTAssertFalse(source.contains("FileManager"), file)
        }
        XCTAssertFalse(try appSource("DJRouteSession.swift").contains("UserDefaults"))
    }

    // MARK: Fetch hygiene (privacy)

    func testTheFetchIsAnHTTPSBareGETWithNoQueryNoBodyNoAuthAndNoCookies() throws {
        let request = try XCTUnwrap(DJAirPlayRouteFlag.request(baseURL: DJAirPlayRouteFlag.proxyBaseURL))
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.absoluteString, "https://aerodj-tts.vercel.app/api/flags")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.allHTTPHeaderFields ?? [:], [:], "no auth, install or user header")
        XCTAssertLessThanOrEqual(request.timeoutInterval, 5)
        // A query, fragment or user info on the base never reaches the request.
        let dirty = try XCTUnwrap(DJAirPlayRouteFlag.request(baseURL: URL(string: "https://u:p@proxy.invalid/?install=1#x")!))
        XCTAssertNil(dirty.url?.query)
        XCTAssertNil(dirty.url?.fragment)
        XCTAssertNil(dirty.url?.user)
        XCTAssertNil(dirty.url?.password)
        // Not HTTPS: no request at all.
        for base in ["http://aerodj-tts.vercel.app", "ftp://proxy.invalid", "file:///tmp"] {
            XCTAssertNil(DJAirPlayRouteFlag.request(baseURL: URL(string: base)!), base)
        }
    }

    func testANonHTTPSBaseSendsNothingAndKeepsTheStoredValue() async throws {
        let store = DJAirPlayFlagStore()
        let spy = FlagTransport(status: 200, body: #"{"djAirPlayLongForm":false}"#)
        let value = await DJAirPlayRouteFlag.refresh(transport: spy, baseURL: URL(string: "http://proxy.invalid")!, store: store)
        XCTAssertTrue(value, "nothing fetched: fail open")
        XCTAssertTrue(spy.requests.isEmpty, "no plain-HTTP request is ever sent")
    }

    func testTheFetchSessionIsEphemeralWithNoCookiesNoCacheAndAShortTimeout() {
        let config = DJAirPlayRouteFlag.sessionConfiguration()
        XCTAssertNil(config.httpCookieStorage, "no cookie storage")
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
        XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForRequest, 5)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForResource, 5)
        XCTAssertTrue(config.httpAdditionalHeaders?.isEmpty ?? true, "no extra headers")
    }

    // MARK: Echo's N1: route re-check before a talk-over

    func testTheTalkoverIsDowngradedOnlyOnAirPlayWithTheSwitchOn() {
        let decisions: [TalkoverDecision] = [.talkover(Self.plan)] + TalkoverHardBreak.allCases.map { .hardBreak($0) }
        for planned in decisions {
            for route in LongFormRouteKind.allCases {
                for flag in [false, true] {
                    var recheck = DJRouteRecheck()
                    let checked = recheck.talkoverBoundary(planned, lastProbedRoute: route, sessionRoute: .builtIn, airPlayFlag: flag)
                    if planned.plan != nil, flag, route == .airPlay {
                        XCTAssertEqual(checked, .hardBreak(.airPlayRoute), "AirPlay: a gap break")
                    } else {
                        XCTAssertEqual(checked, planned, "unchanged: \(planned) route=\(route) flag=\(flag)")
                    }
                }
            }
        }
    }

    func testADowngradedTalkoverAirsTheSameLinesWithoutTheTalkoverMarker() async throws {
        let taken = try await prepared(talkOverEnabled: { true })
        XCTAssertNotNil(taken.talkOverCueID, "taken as a talk-over")
        let gap = DJTalkoverRouteCheck.gapBreak(from: taken)
        XCTAssertNil(gap.talkOverCueID)
        XCTAssertNil(gap.talkOverStartSeconds, "nothing timed to the next intro")
        XCTAssertNil(gap.talkOverSeconds)
        XCTAssertEqual(gap.cues, taken.cues, "same lines")
        XCTAssertEqual(gap.clips, taken.clips, "same audio")
        // The same shape as the preparer's own gap-break path.
        let gapPath = try await prepared(talkOverEnabled: { false })
        XCTAssertEqual(gap.talkOverCueID, gapPath.talkOverCueID)
        XCTAssertEqual(gap.talkOverStartSeconds, gapPath.talkOverStartSeconds)
        XCTAssertEqual(gap.cues.map(\.text), gapPath.cues.map(\.text))
    }

    func testTheCoordinatorRechecksTheRouteBeforeCommittingTheTalkover() throws {
        let take = try body(appSource("TalkoverCoordinator.swift"), "private func take(")
        let planner = try XCTUnwrap(take.range(of: "let planned = TalkoverPlanner.decide("))
        let check = try XCTUnwrap(take.range(of: "let decision = DJRouteSession.talkoverDecision(planned, afterTrack: k)"))
        let strip = try XCTUnwrap(take.range(of: "held = (k, DJTalkoverRouteCheck.gapBreak(from: h.prepared))"))
        let decide = try XCTUnwrap(take.range(of: "decide(decision, afterTrack: k)"))
        let run = try XCTUnwrap(take.range(of: "run = TalkoverRun(afterTrack: k, plan: plan)"))
        let duck = try XCTUnwrap(take.range(of: "interlude.duckForTalkover(afterTrack: k)"))
        XCTAssertLessThan(planner.lowerBound, check.lowerBound)
        XCTAssertLessThan(check.lowerBound, strip.lowerBound)
        XCTAssertLessThan(strip.lowerBound, decide.lowerBound)
        XCTAssertLessThan(decide.lowerBound, run.lowerBound, "checked before the run exists")
        XCTAssertLessThan(run.lowerBound, duck.lowerBound, "and before the duck")
        XCTAssertFalse(take.contains("DJRouteSession.probe"), "no probe while music plays (Fry's bar)")
        XCTAssertFalse(take.contains("setCategory"), "no category change at the re-check")
        let source = try appSource("DJRouteSession.swift")
        let talk = try body(source, "@MainActor static func talkoverDecision(")
        XCTAssertTrue(talk.hasPrefix("\n        let recheck = core.talkoverRecheck(planned, session: session)"), "reads only; Core pins the zero calls")
        XCTAssertTrue(talk.contains("trace(.recheck(recheck, k))"), "Echo: the re-check's DIAG row")
        for banned in ["setCategory", "setActive", "probe", "fetch"] { XCTAssertFalse(talk.contains(banned), banned) }
        XCTAssertTrue(source.contains("transport: DJAirPlayRouteFlag.makeTransport()"), "the ephemeral transport")
        XCTAssertFalse(source.contains("URLSessionTransport()"), "never the shared session")
    }

    // MARK: Fry's bar: session calls against 4a2537b2 (counting fake)

    /// The calls 4a2537b2 makes, derived from its code (explicit calls only; `AVAudioPlayer.play()`
    /// activates the session implicitly and is not a call):
    /// - Gap break: `MusicKitService.completeNarration` -> `releaseSessionAfterBreak` ->
    ///   `setActive(false, .notifyOthersOnDeactivation)`. Resume: `activateAudioSessionForPlayback`
    ///   is gated by `AudioSessionActivation.shouldActivate(.playback)`, which is false: no call.
    /// - Talk-over boundary: `TalkoverSessionSequence.duck` (`setActive(false)`, `setCategory`
    ///   `.duckOthers`, `setActive(true)`), the talk-over's own `release` (`setActive(false,
    ///   notify)`, `setCategory` `.mixWithOthers`), then `completeNarration`'s
    ///   `setActive(false, notify)`.
    /// - Song start: none (`configureAudioSession` sets the category once at launch; the activation
    ///   is gated off).
    static let baselineGap: [CountingSession.Call] = [.setActive(false, notify: true)]
    static let baselineTalkover: [CountingSession.Call] = [
        .setActive(false, notify: false), .setCategory(.default, 0x2), .setActive(true, notify: false),
        .setActive(false, notify: true), .setCategory(.default, 0x1),
        .setActive(false, notify: true),
    ]
    static let probePair: [CountingSession.Call] = [.setCategory(.longFormAudio, 0), .setCategory(.default, 0x1)]

    @MainActor
    func testTheSessionCallsMatch4a2537b2KilledAndOffAirPlayAndTalkoverNeverProbes() {
        // Fry's three cases (plus AirPlay killed). Each case: a gap break and a talk-over boundary.
        let cases: [(name: String, flag: Bool, longForm: [LongFormPortType], local: [LongFormPortType])] = [
            ("killed headphones", false, [.headphones], [.headphones]),
            ("killed AirPlay", false, [.airPlay], [.builtInSpeaker]),
            ("killed speaker", false, [.builtInSpeaker], [.builtInSpeaker]),
            ("on headphones", true, [.headphones], [.headphones]),
            ("on speaker", true, [.builtInSpeaker], [.builtInSpeaker]),
            ("on Bluetooth", true, [.bluetoothA2DP], [.bluetoothA2DP]),
            ("on CarPlay", true, [.carAudio], [.carAudio]),
        ]
        for c in cases {
            let gapSession = CountingSession(longForm: c.longForm, local: c.local)
            let gapCore = DJRouteSessionCore(state: DJLongFormRouteState(flag: { c.flag }), flag: { c.flag })
            Self.gapBreak(gapCore, gapSession)
            let expectedGap = c.flag ? Self.probePair + Self.baselineGap : Self.baselineGap
            XCTAssertEqual(gapSession.calls, expectedGap, "\(c.name): gap break")
            XCTAssertFalse(gapSession.calls.contains { if case .setActive = $0 { return $0 != .setActive(false, notify: true) } else { return false } },
                           "\(c.name): no setActive of ours")

            let talkSession = CountingSession(longForm: c.longForm, local: c.local)
            let talkCore = DJRouteSessionCore(state: DJLongFormRouteState(flag: { c.flag }), flag: { c.flag })
            Self.talkoverBoundary(talkCore, talkSession)
            XCTAssertEqual(talkSession.calls, Self.baselineTalkover, "\(c.name): talk-over, no probe")

            // Song start: killed none; switch on, one pair at the first song start of a launch only.
            let songSession = CountingSession(longForm: c.longForm, local: c.local)
            let songCore = DJRouteSessionCore(state: DJLongFormRouteState(flag: { c.flag }), flag: { c.flag })
            for _ in 0..<3 { _ = songCore.probeBeforeSong(songSession) }
            XCTAssertEqual(songSession.calls, c.flag ? Self.probePair : [], "\(c.name): song starts")
        }
        // A killed gap break after a launch with a song start: still exactly the baseline.
        let s = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { false }), flag: { false })
        XCTAssertNil(core.probeBeforeSong(s))
        Self.gapBreak(core, s)
        Self.talkoverBoundary(core, s)
        XCTAssertEqual(s.calls, Self.baselineGap + Self.baselineTalkover, "killed: exactly 4a2537b2")
    }

    @MainActor
    func testOnAirPlayWithTheSwitchOnOnlyTheGapBreakTakesTheLongFormSession() {
        let s = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { true }), flag: { true })
        let gap = Self.gapBreak(core, s)
        XCTAssertEqual(gap.shape, .longFormAirPlay)
        XCTAssertTrue(gap.fetch, "the first AirPlay gap break may fetch")
        XCTAssertEqual(s.calls, [.setCategory(.longFormAudio, 0), .setActive(false, notify: true), .setCategory(.default, 0x1)],
                       "long-form kept for the clip, today's category back after the release")
        // The talk-over boundary after it is a gap break (no duck), with one more probe.
        s.calls = []
        let decision = Self.talkoverBoundary(core, s)
        XCTAssertEqual(decision, .hardBreak(.airPlayRoute))
        XCTAssertEqual(s.calls, [.setCategory(.longFormAudio, 0), .setActive(false, notify: true), .setCategory(.default, 0x1)])
        XCTAssertFalse(core.beginGapBreak(s).fetch, "at most one fetch per launch")
    }

    @MainActor
    func testAKilledGapBreakFetchesOnlyIfTheSessionsOwnRouteShowsAirPlay() {
        // Killed: no probe, so the route is read as-is. If the app's session shows AirPlay the
        // first AirPlay gap break can lift a false; if it shows the phone (the documented risk),
        // it cannot.
        let shows = CountingSession(longForm: [.airPlay], local: [.airPlay])
        let a = DJRouteSessionCore(state: DJLongFormRouteState(flag: { false }), flag: { false })
        XCTAssertTrue(a.beginGapBreak(shows).fetch)
        let local = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        let b = DJRouteSessionCore(state: DJLongFormRouteState(flag: { false }), flag: { false })
        XCTAssertFalse(b.beginGapBreak(local).fetch)
        XCTAssertEqual(shows.calls + local.calls, [], "no session call while killed")
    }

    // MARK: Fry's launch-probe conditions

    /// The launch probe on its own: one probe pair at the first song start of a launch (switch on),
    /// never `setActive`; then song starts add nothing, and the gap break and talk-over make exactly
    /// their Fry's-bar calls. Killed: nothing at all.
    @MainActor
    func testTheLaunchProbeIsOnePairThenNothingExtra() {
        let s = CountingSession(longForm: [.headphones], local: [.headphones])
        let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { true }), flag: { true })
        let launch = core.probeBeforeSong(s)
        XCTAssertEqual(launch?.site, .launch)
        XCTAssertEqual(launch?.sessionPorts, [.headphones], "raw port types for the DIAG row")
        XCTAssertEqual(launch?.ports, [.headphones])
        XCTAssertEqual(s.calls, Self.probePair, "one pair at launch, no setActive")
        for _ in 0..<5 { XCTAssertNil(core.probeBeforeSong(s), "never a second launch probe") }
        XCTAssertEqual(s.calls, Self.probePair, "nothing extra at later song starts")
        s.calls = []
        Self.talkoverBoundary(core, s)
        XCTAssertEqual(s.calls, Self.baselineTalkover, "talk-over after the launch probe: exactly 4a2537b2")
        s.calls = []
        Self.gapBreak(core, s)
        XCTAssertEqual(s.calls, Self.probePair + Self.baselineGap, "the gap break's own pair only")
        XCTAssertNil(core.probeBeforeSong(s))
        // Killed launch: no launch probe.
        let k = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        let killed = DJRouteSessionCore(state: DJLongFormRouteState(flag: { false }), flag: { false })
        XCTAssertNil(killed.probeBeforeSong(k))
        XCTAssertEqual(k.calls, [])
    }

    /// Synchronous on the main actor, before `prepareToPlay()` and our first `play()`: it cannot
    /// race MusicKit's start.
    func testTheLaunchProbeRunsSynchronouslyBeforeTheFirstPlay() throws {
        let service = try appSource("MusicKitService.swift")
        XCTAssertTrue(service.contains("@MainActor\nfinal class MusicKitService"), "main actor")
        let play = try body(service, "private func playIfStillAllowed(")
        let probe = try XCTUnwrap(play.range(of: "DJRouteSession.probeBeforeSong()"))
        let prepare = try XCTUnwrap(play.range(of: "try await player.prepareToPlay()"))
        let start = try XCTUnwrap(play.range(of: "try await player.play()"))
        XCTAssertLessThan(probe.lowerBound, prepare.lowerBound)
        XCTAssertLessThan(probe.lowerBound, start.lowerBound)
        XCTAssertFalse(play[..<probe.lowerBound].contains("await"), "no suspension before the probe")
        let source = try appSource("DJRouteSession.swift")
        let song = try body(source, "@MainActor static func probeBeforeSong()")
        XCTAssertFalse(song.contains("await"), "the probe itself never suspends")
        XCTAssertFalse(song.contains("Task {"), "and never hops queues (only the fetch is detached)")
        XCTAssertTrue(song.contains("trace(.probe(p,"), "it writes the DIAG row")
    }

    // MARK: Fry's #527 B1: a failed `.normal` restore is retried, then latched

    static let normalCall: CountingSession.Call = .setCategory(.default, 0x1)
    static let longFormCall: CountingSession.Call = .setCategory(.longFormAudio, 0)

    @MainActor
    private func core(_ flag: Bool, _ events: @escaping @MainActor (DJRouteSessionCore.RestoreEvent) -> Void) -> DJRouteSessionCore {
        let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { flag }), flag: { flag })
        core.onRestore = events
        return core
    }

    @MainActor
    func testAFailedProbeRestoreSucceedsOnRetry() {
        var events: [DJRouteSessionCore.RestoreEvent] = []
        let s = CountingSession(longForm: [.headphones], local: [.headphones])
        let core = core(true) { events.append($0) }
        s.failNormal = 1
        Self.gapBreak(core, s)
        XCTAssertEqual(s.calls, [Self.longFormCall, Self.normalCall, Self.normalCall] + Self.baselineGap,
                       "one retry, only on failure")
        XCTAssertEqual(events, [.failed(.probe, attempt: 1), .recovered(.probe, attempt: 2)])
        XCTAssertFalse(core.restorePending)
        s.calls = []
        Self.talkoverBoundary(core, s)
        XCTAssertEqual(s.calls, Self.baselineTalkover, "recovered: the talk-over is exactly 4a2537b2 again")
    }

    @MainActor
    func testARestoreThatFailsTwiceLatchesForcesAGapBreakAndReappliesBeforeTheNextPlay() {
        var events: [DJRouteSessionCore.RestoreEvent] = []
        let s = CountingSession(longForm: [.headphones], local: [.headphones])
        let core = core(true) { events.append($0) }
        s.failNormal = 2
        _ = core.beginGapBreak(s)
        XCTAssertEqual(s.calls, [Self.longFormCall, Self.normalCall, Self.normalCall])
        XCTAssertEqual(events, [.failed(.probe, attempt: 1), .failed(.probe, attempt: 2), .latched(.probe)])
        XCTAssertTrue(core.restorePending)
        // Every talk-over is forced to a gap break while the restore is pending, with no session call.
        s.calls = []
        XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .hardBreak(.restoreFailed))
        let recheck = core.talkoverRecheck(.talkover(Self.plan), session: s)
        XCTAssertEqual(recheck.decision, .hardBreak(.restoreFailed), "the re-check row reports it")
        XCTAssertEqual(core.talkoverDecision(.hardBreak(.tooLateToArm), session: s), .hardBreak(.tooLateToArm), "a planned hard break stays")
        XCTAssertEqual(s.calls, [])
        // Before the next play(): `.normal` is re-applied (the launch probe is already done).
        events = []
        XCTAssertNil(core.probeBeforeSong(s))
        XCTAssertEqual(s.calls, [Self.normalCall], "re-applied before play()")
        XCTAssertEqual(events, [.cleared(.beforePlay)])
        XCTAssertFalse(core.restorePending)
        XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .talkover(Self.plan), "talk-over again")
        // The endGapBreak restore: AirPlay long-form clip, restore fails twice, re-applied before the
        // next clip, ahead of that break's own probe.
        var airEvents: [DJRouteSessionCore.RestoreEvent] = []
        let a = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        let air = self.core(true) { airEvents.append($0) }
        let gap = air.beginGapBreak(a)
        XCTAssertEqual(gap.shape, .longFormAirPlay)
        a.failNormal = 2
        air.endGapBreak(a, shape: gap.shape)
        XCTAssertEqual(airEvents, [.failed(.endGapBreak, attempt: 1), .failed(.endGapBreak, attempt: 2), .latched(.endGapBreak)])
        a.calls = []
        _ = air.beginGapBreak(a)
        XCTAssertEqual(a.calls.first, Self.normalCall, "re-applied before the next clip")
        XCTAssertEqual(airEvents.last, .cleared(.beforeClip))
        XCTAssertFalse(air.restorePending)
    }

    @MainActor
    func testTheLatchStaysWhileTheReapplyFailsAndClearsAfterSuccess() {
        var events: [DJRouteSessionCore.RestoreEvent] = []
        let s = CountingSession(longForm: [.headphones], local: [.headphones])
        let core = core(true) { events.append($0) }
        s.failNormal = 2
        _ = core.beginGapBreak(s)
        XCTAssertTrue(core.restorePending)
        // The re-apply before play() fails twice too: still pending, and reported.
        s.failNormal = 2
        events = []
        _ = core.probeBeforeSong(s)
        XCTAssertEqual(events, [.failed(.beforePlay, attempt: 1), .failed(.beforePlay, attempt: 2), .latched(.beforePlay)])
        XCTAssertTrue(core.restorePending)
        XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .hardBreak(.restoreFailed))
        // Never on an active session.
        s.appActivated = true
        s.calls = []
        _ = core.probeBeforeSong(s)
        XCTAssertEqual(s.calls, [], "no category change while our session is active")
        s.appActivated = false
        // Succeeds: cleared, and the talk-over is back.
        events = []
        _ = core.probeBeforeSong(s)
        XCTAssertEqual(events, [.cleared(.beforePlay)])
        XCTAssertFalse(core.restorePending)
        XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .talkover(Self.plan))
        // A recovered retry also clears a latch.
        s.failNormal = 2
        _ = core.beginGapBreak(s)
        XCTAssertTrue(core.restorePending)
        s.failNormal = 1
        events = []
        _ = core.probeBeforeSong(s)
        XCTAssertEqual(events, [.failed(.beforePlay, attempt: 1), .recovered(.beforePlay, attempt: 2), .cleared(.beforePlay)])
        XCTAssertFalse(core.restorePending)
    }

    @MainActor
    func testAFailedLongFormSetNeverKeepsLongFormAndStillRestores() {
        var events: [DJRouteSessionCore.RestoreEvent] = []
        let s = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        let state = DJLongFormRouteState(flag: { true })
        let core = DJRouteSessionCore(state: state, flag: { true })
        core.onRestore = { events.append($0) }
        state.record(.wired)
        s.failLongForm = 1
        let gap = core.beginGapBreak(s)
        XCTAssertEqual(gap.shape, .mixDefault, "long-form is never kept when its set failed")
        XCTAssertEqual(gap.probe?.setFailed, true)
        XCTAssertEqual(gap.probe?.ports, [], "nothing read under the wrong category")
        XCTAssertFalse(gap.fetch)
        XCTAssertEqual(state.lastRoute, .wired, "nothing recorded")
        XCTAssertEqual(s.calls, [Self.longFormCall, Self.normalCall], "the restore still runs")
        XCTAssertEqual(events, [])
        XCTAssertFalse(core.restorePending)
    }

    @MainActor
    func testKilledPathsStayZeroTouchEvenWithAThrowingSession() {
        let s = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        s.failNormal = 5
        s.failLongForm = 5
        let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { false }), flag: { false })
        XCTAssertNil(core.probeBeforeSong(s))
        _ = core.beginGapBreak(s)
        core.endGapBreak(s, shape: .mixDefault)
        XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .talkover(Self.plan))
        XCTAssertEqual(s.calls, [], "killed: zero session calls")
        XCTAssertFalse(core.restorePending)
    }

    /// Fry's N1 (#527, 093a4a13): the accepted latch-then-killed case. The switch is on, the restore
    /// fails twice (latched), then the switch is killed. The next `probeBeforeSong` (before play()) or
    /// `beginGapBreak` (before the clip) still re-applies `.normal` exactly once and clears the latch,
    /// and after that the killed paths make no further session call.
    @MainActor
    func testALatchSetBeforeAKillIsReappliedExactlyOnceThenKilledIsZeroTouch() {
        for site in [DJRouteSessionCore.RestoreSite.beforePlay, .beforeClip] {
            var on = true
            var events: [DJRouteSessionCore.RestoreEvent] = []
            let s = CountingSession(longForm: [.headphones], local: [.headphones])
            let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { on }), flag: { on })
            core.onRestore = { events.append($0) }
            s.failNormal = 2
            _ = core.beginGapBreak(s)
            XCTAssertTrue(core.restorePending, "\(site): latched with the switch on")
            on = false
            // Killed and latched: the talk-over still cannot duck a possibly long-form session.
            s.calls = []
            events = []
            XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .hardBreak(.restoreFailed), "\(site)")
            XCTAssertEqual(s.calls, [], "\(site): the re-check makes no call")
            // The next boundary re-applies `.normal` exactly once, whatever the switch, and clears.
            if site == .beforePlay {
                XCTAssertNil(core.probeBeforeSong(s), "\(site): killed, no launch probe")
            } else {
                let gap = core.beginGapBreak(s)
                XCTAssertNil(gap.probe, "\(site): killed, no probe")
                XCTAssertEqual(gap.shape, .mixDefault, "\(site)")
            }
            XCTAssertEqual(s.calls, [Self.normalCall], "\(site): exactly one .normal")
            XCTAssertEqual(events, [.cleared(site)], "\(site)")
            XCTAssertFalse(core.restorePending, "\(site)")
            // Then killed is zero-touch again: no further call at any boundary.
            s.calls = []
            events = []
            XCTAssertNil(core.probeBeforeSong(s))
            let gap = core.beginGapBreak(s)
            core.endGapBreak(s, shape: gap.shape)
            XCTAssertNil(core.probeBeforeSong(s))
            XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .talkover(Self.plan), "\(site): killed, talk-over as today")
            XCTAssertEqual(s.calls, [], "\(site): no further session call")
            XCTAssertEqual(events, [], "\(site)")
        }
    }

    // MARK: Orion's call: routeChangeNotification marks the next boundary

    /// Song starts on headphones, the listener picks AirPlay mid-song, the next boundary is a
    /// planned talk-over: it becomes a hard break, never a talk-over, with no session call.
    @MainActor
    func testARouteChangeToAirPlayMidSongDowngradesTheNextTalkover() {
        for sessionShowsAirPlay in [false, true] {
            let s = CountingSession(longForm: [.headphones], local: [.headphones])
            let state = DJLongFormRouteState(flag: { true })
            let core = DJRouteSessionCore(state: state, flag: { true })
            XCTAssertNotNil(core.probeBeforeSong(s), "song start on headphones")
            XCTAssertEqual(state.lastRoute, .wired)
            XCTAssertTrue(state.talkoverAllowed)
            // Mid-song (music playing): AirPlay picked.
            s.longForm = [.airPlay]
            s.local = sessionShowsAirPlay ? [.airPlay] : [.builtInSpeaker]
            XCTAssertTrue(core.routeChanged(.newDeviceAvailable), "marked for the re-check")
            s.calls = []
            let decision = core.talkoverDecision(.talkover(Self.plan), session: s)
            XCTAssertNil(decision.plan, "not a talk-over")
            XCTAssertEqual(decision, .hardBreak(sessionShowsAirPlay ? .airPlayRoute : .routeChanged))
            XCTAssertEqual(s.calls, [], "the re-check makes no session call")
            XCTAssertFalse(core.recheck.pending, "the boundary consumed the mark")
            // That boundary airs in the gap: its probe reads the real route and takes AirPlay.
            XCTAssertEqual(core.beginGapBreak(s).shape, .longFormAirPlay)
            XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .hardBreak(.airPlayRoute))
        }
    }

    @MainActor
    func testTheRouteChangeMarkHasNoEffectKilledIgnoresOurOwnCategoryChangesAndIsClearedByAProbe() {
        let s = CountingSession(longForm: [.headphones], local: [.headphones])
        var flag = false
        let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { flag }), flag: { flag })
        for reason in DJRouteChangeReason.allCases { XCTAssertFalse(core.routeChanged(reason), "killed: \(reason)") }
        XCTAssertFalse(core.recheck.pending)
        XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .talkover(Self.plan))
        flag = true
        XCTAssertFalse(core.routeChanged(.categoryChange), "our own setCategory is not a route change")
        XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .talkover(Self.plan), "no change: talk-over")
        XCTAssertTrue(core.routeChanged(.oldDeviceUnavailable))
        _ = core.beginGapBreak(s)
        XCTAssertFalse(core.recheck.pending, "a probe reads the real route")
        XCTAssertEqual(core.talkoverDecision(.talkover(Self.plan), session: s), .talkover(Self.plan), "headphones: talk-over")
        XCTAssertEqual(s.calls, Self.probePair, "only the gap break's pair")
    }

    func testTheRouteChangeObserverIsRemovedAndMakesNoSessionOrNetworkCall() throws {
        let source = try appSource("DJRouteSession.swift")
        let observer = try XCTUnwrap(source.range(of: "@MainActor final class DJRouteChangeObserver {"))
        let tail = String(source[observer.lowerBound...])
        XCTAssertEqual(tail.components(separatedBy: "addObserver(forName: AVAudioSession.routeChangeNotification").count - 1, 1)
        XCTAssertTrue(tail.contains("guard token == nil else { return }"), "added once")
        XCTAssertEqual(tail.components(separatedBy: "NotificationCenter.default.removeObserver(token)").count - 1, 2, "stop() and deinit")
        let handler = try body(source, "@MainActor static func routeChanged(_ reason: DJRouteChangeReason)")
        for banned in ["setCategory", "setActive", "refresh", "probe", "Task"] {
            XCTAssertFalse(handler.contains(banned), "handler: \(banned)")
            XCTAssertFalse(tail.contains(banned), "observer: \(banned)")
        }
        let coordinator = try appSource("TalkoverCoordinator.swift")
        XCTAssertTrue(coordinator.contains("private let routeChanges = DJRouteChangeObserver()"))
        let start = try body(coordinator, "func start()")
        XCTAssertTrue(start.contains("routeChanges.start()"))
    }

    // MARK: Fetch gate (privacy)

    func testNoFetchOffAirPlayAndAtMostOnePerLaunchAtTheFirstAirPlayDetection() {
        // Off AirPlay: never, at any probe, however many breaks.
        var offAirPlay = DJAirPlayFlagFetchGate()
        for route in LongFormRouteKind.allCases where route != .airPlay {
            for event in DJAirPlayFlagFetchGate.ProbeEvent.allCases {
                for _ in 0..<3 { XCTAssertFalse(offAirPlay.shouldFetch(route: route, at: event), "\(route) \(event)") }
            }
        }
        XCTAssertFalse(offAirPlay.fetched)
        // Orion (Nov 14): the launch probe on AirPlay fetches; then never again this launch.
        var launch = DJAirPlayFlagFetchGate()
        XCTAssertFalse(launch.shouldFetch(route: .bluetooth, at: .songStart))
        XCTAssertTrue(launch.shouldFetch(route: .airPlay, at: .songStart), "the launch probe on AirPlay fetches")
        var later = 0
        for route in LongFormRouteKind.allCases {
            for event in DJAirPlayFlagFetchGate.ProbeEvent.allCases where launch.shouldFetch(route: route, at: event) { later += 1 }
        }
        XCTAssertEqual(later, 0, "at most one fetch per launch")
        // Not on AirPlay at launch: the first AirPlay gap break fetches.
        var gap = DJAirPlayFlagFetchGate()
        XCTAssertFalse(gap.shouldFetch(route: .wired, at: .songStart))
        XCTAssertTrue(gap.shouldFetch(route: .airPlay, at: .gapBreak))
        // A new launch (a new gate) may fetch once again.
        var next = DJAirPlayFlagFetchGate()
        XCTAssertTrue(next.shouldFetch(route: .airPlay, at: .gapBreak))
    }

    @MainActor
    func testTheCoreNeverFetchesOffAirPlayAtAnyProbe() {
        for ports in [[LongFormPortType.headphones], [.builtInSpeaker], [.bluetoothA2DP], [.carAudio], []] {
            for flag in [true, false] {
                let s = CountingSession(longForm: ports, local: ports)
                let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { flag }), flag: { flag })
                XCTAssertNotEqual(core.probeBeforeSong(s)?.fetch, true)
                for _ in 0..<3 { XCTAssertFalse(core.beginGapBreak(s).fetch, "\(ports) flag=\(flag)") }
                XCTAssertFalse(core.fetchGate.fetched)
            }
        }
    }

    // MARK: Route state

    func testTalkoverIsRefusedOnlyWithTheFlagOnAndAirPlay() {
        var flag = false
        let state = DJLongFormRouteState(flag: { flag })
        XCTAssertTrue(state.talkoverAllowed, "no probe yet")
        XCTAssertFalse(state.record(.airPlay), "flag off: AirPlay changes nothing")
        XCTAssertTrue(state.talkoverAllowed)
        flag = true
        XCTAssertFalse(state.talkoverAllowed)
        XCTAssertFalse(state.preparerTalkOverEnabled(talkoverFlag: true))
        XCTAssertTrue(state.record(.bluetooth), "the permission changed: reported")
        XCTAssertTrue(state.talkoverAllowed)
        XCTAssertTrue(state.preparerTalkOverEnabled(talkoverFlag: true))
        XCTAssertFalse(state.preparerTalkOverEnabled(talkoverFlag: false), "the Settings toggle still rules")
        XCTAssertFalse(state.record(.carPlay), "no change, no report")
        XCTAssertTrue(state.record(.airPlay))
    }

    // MARK: Echo: the AirPlay fallback airs a gap-break script

    /// On AirPlay the preparer renders the break on its gap-break path: the closing line carries
    /// no talk-over marker and no talk-over start, so nothing is timed to the next song's intro.
    func testOnAirPlayTheBreakIsPreparedOnTheGapBreakPathNotAsATalkover() async throws {
        let state = DJLongFormRouteState(flag: { true })
        state.record(.airPlay)
        let onAirPlay = try await prepared(talkOverEnabled: { state.preparerTalkOverEnabled(talkoverFlag: true) })
        XCTAssertNil(onAirPlay.talkOverCueID, "gap-break path: no talk-over closing cue")
        XCTAssertNil(onAirPlay.talkOverStartSeconds)
        XCTAssertNil(onAirPlay.talkOverSeconds)
        XCTAssertEqual(onAirPlay.clips.count, 2, "the same lines, spoken in the gap")

        // Control: the same break off AirPlay keeps today's talk-over marker.
        let other = DJLongFormRouteState(flag: { true })
        other.record(.builtIn)
        let onSpeaker = try await prepared(talkOverEnabled: { other.preparerTalkOverEnabled(talkoverFlag: true) })
        XCTAssertNotNil(onSpeaker.talkOverCueID)
        XCTAssertNotNil(onSpeaker.talkOverStartSeconds)
    }

    // MARK: DIAG rows (the trace exists only in DEBUG or AERODJ_P0_DIAG builds; the release
    // test build in check-release-disables-paid-voice.sh compiles without it)

    #if DEBUG || AERODJ_P0_DIAG
    func testEveryRouteKindPortTypeAndShapeHasATraceCode() {
        for r in LongFormRouteKind.allCases { XCTAssertNotNil(P0TraceCode(rawValue: r.rawValue), "\(r)") }
        for p in LongFormPortType.allCases { XCTAssertNotNil(P0TraceCode(rawValue: p.rawValue), "\(p)") }
        for s in DJSessionShape.allCases { XCTAssertNotNil(P0TraceCode(rawValue: s.rawValue), "\(s)") }
        XCTAssertNotNil(P0TraceCode(rawValue: TalkoverHardBreak.airPlayRoute.rawValue))
        XCTAssertNotNil(P0TraceCode(rawValue: TalkoverHardBreak.routeChanged.rawValue))
        XCTAssertNotNil(P0TraceCode(rawValue: TalkoverHardBreak.restoreFailed.rawValue))
        for s in DJRouteSessionCore.RestoreSite.allCases { XCTAssertNotNil(P0TraceCode(rawValue: s.rawValue), "\(s)") }
        for r in DJRouteChangeReason.allCases { XCTAssertNotNil(P0TraceCode(rawValue: r.rawValue), "\(r)") }
    }

    func testTheRouteRowsCarryPortTypesAndShapesOnly() {
        var trace = P0EventTrace()
        let probe = trace.sessionRouteProbe(route: .airPlay, ports: [.airPlay, .builtInSpeaker, .bluetoothA2DP], flag: true,
                                            talkoverAllowed: false, changed: true, at: 3)
        XCTAssertEqual(probe.event, .sessionRoute)
        XCTAssertEqual(probe.detail, "kind=probe route=airPlay port1=airPlay port2=builtInSpeaker ports=3 cur1=- cur2=- curN=0 flag=1 allowed=0 changed=1")
        let shape = trace.sessionBreakShape(.longFormAirPlay, route: .airPlay, afterTrack: 4, at: 4)
        XCTAssertEqual(shape.detail, "kind=breakShape after=4 shape=longFormAirPlay route=airPlay cur1=- cur2=- curN=0 port1=- port2=- ports=0")
        let skipped = trace.sessionRouteProbeSkipped(flag: true, at: 5)
        XCTAssertEqual(skipped.detail, "kind=probeSkipped flag=1")
        let change = trace.sessionRouteChange(.newDeviceAvailable, marked: true, flag: true, at: 5)
        XCTAssertEqual(change.detail, "kind=routeChange reason=newDeviceAvailable changed=1 flag=1")
        let changed = trace.talkoverDecision(.hardBreak(.routeChanged), afterTrack: 4, at: 6)
        XCTAssertEqual(changed.detail, "kind=decision after=4 mode=hardBreak reason=routeChanged")
        let fallback = trace.talkoverDecision(.hardBreak(.airPlayRoute), afterTrack: 4, at: 6)
        XCTAssertEqual(fallback.detail, "kind=decision after=4 mode=hardBreak reason=airPlayRoute")
        XCTAssertEqual(TalkoverLog.decision(afterTrack: 4, .hardBreak(.airPlayRoute)),
                       "talkover plan after=4 result=hardBreak reason=airPlayRoute")
    }
    #endif

    // MARK: App wiring (source pins; the app target does not build on Linux)

    func testTheGapBreakAppliesTheRouteSessionAroundTheClipAndRestoresAfterRelease() throws {
        let run = try body(appSource("InterludePlaybackAdapter.swift"), "private func runBreak(")
        let pause = try XCTUnwrap(run.range(of: "music.pausePlayerForBreak()"))
        let begin = try XCTUnwrap(run.range(of: "DJRouteSession.beginGapBreak(afterTrack: breakTrack)"))
        let start = try XCTUnwrap(run.range(of: "if start() {"))
        let complete = try XCTUnwrap(run.range(of: "music.completeNarration(decision)"))
        let end = try XCTUnwrap(run.range(of: "DJRouteSession.endGapBreak(sessionShape)"))
        let resume = try XCTUnwrap(run.range(of: "await music.resumeIfAllowed()"))
        XCTAssertLessThan(pause.lowerBound, begin.lowerBound, "music is paused before the long-form session")
        XCTAssertLessThan(begin.lowerBound, start.lowerBound)
        XCTAssertLessThan(complete.lowerBound, end.lowerBound, "released (notify others) before the category goes back")
        XCTAssertLessThan(end.lowerBound, resume.lowerBound, "back to today's category before music resumes")
        // The talk-over path never uses the long-form session.
        let talk = try body(appSource("InterludePlaybackAdapter.swift"), "func playTalkover(")
        XCTAssertFalse(talk.contains("DJRouteSession"))
    }

    func testTheRouteSessionFetchesOnlyFromTheGapBreakGateAndProbesSafely() throws {
        let source = try appSource("DJRouteSession.swift")
        // The only network call sits behind Core's gate (`GapBreak.fetch`), in the gap break.
        XCTAssertEqual(source.components(separatedBy: "DJAirPlayRouteFlag.refresh(").count - 1, 1)
        let fetch = try body(source, "@MainActor private static func fetchFlag()")
        XCTAssertTrue(fetch.contains("DJAirPlayRouteFlag.refresh("))
        XCTAssertEqual(source.components(separatedBy: "fetchFlag()").count - 1, 3, "declared once, called from Core's two gates")
        let begin = try body(source, "@MainActor static func beginGapBreak(")
        XCTAssertTrue(begin.contains("if gap.fetch { fetchFlag() }"))
        let song = try body(source, "@MainActor static func probeBeforeSong()")
        XCTAssertTrue(song.hasPrefix("\n        guard let p = core.probeBeforeSong(session) else { return }"))
        XCTAssertTrue(song.contains("if p.fetch { fetchFlag() }"), "the launch probe's AirPlay detection (Core gates it)")
        // The only setCategory / setActive calls are the adapter's, driven by Core.
        XCTAssertEqual(source.components(separatedBy: ".setCategory(").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: ".setActive(").count - 1, 1)
        XCTAssertTrue(source.contains("setCategory(.playback, mode: .default, policy: policy, options: options)"),
                      "every category names its route-sharing policy, so long-form cannot linger")
        XCTAssertTrue(source.contains("var appActivated: Bool { TalkoverAudioSession.appActivated }"), "never on an active session")
        // Nothing else in the app fetches the switch.
        for file in ["MusicKitService.swift", "TalkoverCoordinator.swift", "InterludePlaybackAdapter.swift", "AppDependencies.swift"] {
            let other = try appSource(file)
            XCTAssertFalse(other.contains("DJAirPlayRouteFlag.refresh"), file)
            XCTAssertFalse(other.contains("fetchFlag"), file)
        }
    }

    @MainActor
    func testTheCoreProbeGatesTheFetchAndNeverRunsOnAnActiveSession() {
        let s = CountingSession(longForm: [.airPlay], local: [.builtInSpeaker])
        let core = DJRouteSessionCore(state: DJLongFormRouteState(flag: { true }), flag: { true })
        s.appActivated = true
        let skipped = core.beginGapBreak(s)
        XCTAssertTrue(skipped.skipped)
        XCTAssertEqual(skipped.shape, .mixDefault, "a skipped probe keeps today's session")
        XCTAssertFalse(skipped.fetch)
        XCTAssertNil(core.probeBeforeSong(s))
        XCTAssertEqual(s.calls, [], "nothing on an active session")
        s.appActivated = false
        XCTAssertEqual(core.probeBeforeSong(s)?.fetch, true, "Orion: the launch probe on AirPlay fetches (once per launch)")
        XCTAssertTrue(core.fetchGate.fetched)
        XCTAssertFalse(core.beginGapBreak(s).fetch, "and nothing more this launch")
    }

    func testTodaysSessionCallsAreUnchangedOffAirPlay() throws {
        let coordinator = try appSource("TalkoverCoordinator.swift")
        XCTAssertEqual(coordinator.components(separatedBy: "try session.setCategory(.playback, mode: .default, options: [.duckOthers])").count - 1, 1)
        XCTAssertEqual(coordinator.components(separatedBy: "try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)").count - 1, 1)
        XCTAssertFalse(coordinator.contains("longFormAudio"))
        let service = try appSource("MusicKitService.swift")
        XCTAssertEqual(service.components(separatedBy: "try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)").count - 1, 1)
        XCTAssertFalse(service.contains("longFormAudio"))
        let play = try body(service, "private func playIfStillAllowed(")
        let probe = try XCTUnwrap(play.range(of: "DJRouteSession.probeBeforeSong()"))
        let activate = try XCTUnwrap(play.range(of: "try activateAudioSessionForPlayback()"))
        XCTAssertLessThan(probe.lowerBound, activate.lowerBound, "probed before music starts")
    }

    func testTalkoverFallsBackOnAirPlayAndThePreparerFollowsTheRoute() throws {
        let tick = try body(appSource("TalkoverCoordinator.swift"), "private func tick()")
        let guardRoute = try XCTUnwrap(tick.range(of: "guard DJRouteSession.talkoverAllowed else {"))
        let take = try XCTUnwrap(tick.range(of: "taking = Task"))
        XCTAssertLessThan(guardRoute.lowerBound, take.lowerBound, "the boundary is never taken on AirPlay")
        XCTAssertTrue(tick.contains("decide(.hardBreak(.airPlayRoute), afterTrack: k)"), "the fallback is reported")
        let deps = try appSource("AppDependencies.swift")
        XCTAssertEqual(deps.components(separatedBy: "DJLongFormRouteState.shared.preparerTalkOverEnabled(").count - 1, 2,
                       "live and fixture preparers both prepare gap breaks on AirPlay")
        XCTAssertFalse(deps.contains("talkOverEnabled: { DJTalkoverFlag.isEnabled() }"))
    }

    // MARK: Helpers

    static let plan = TalkoverPlan(mode: .outroOnly, introSkip: .noClosingLine, outroOverlap: 4, voiceStartAt: 196,
                                   nextPlayAfterVoice: nil, nextAudibleAfterVoice: nil, unduckAfterVoice: 12,
                                   startLatency: 0.8, voiceSeconds: 12)

    /// A gap break as 4a2537b2 runs it, with the #525 hooks around the clip.
    @MainActor @discardableResult
    static func gapBreak(_ core: DJRouteSessionCore, _ s: CountingSession) -> DJRouteSessionCore.GapBreak {
        let gap = core.beginGapBreak(s)
        s.appActivated = true                       // the clip's play(): implicit activation
        s.setActive(false, notifyOthers: true)      // completeNarration -> releaseSessionAfterBreak
        s.appActivated = false
        core.endGapBreak(s, shape: gap.shape)
        return gap                                  // resume: activation gated off, no call
    }

    /// A talk-over boundary as 4a2537b2 runs it, after the #525 pre-duck re-check. A downgraded
    /// boundary airs as a gap break.
    @MainActor @discardableResult
    static func talkoverBoundary(_ core: DJRouteSessionCore, _ s: CountingSession) -> TalkoverDecision {
        let decision = core.talkoverDecision(.talkover(plan), session: s)
        guard decision.plan != nil else {
            gapBreak(core, s)
            return decision
        }
        for step in TalkoverSessionSequence.duck { s.apply(step) }
        s.appActivated = true
        for step in TalkoverSessionSequence.release { s.apply(step) }
        s.appActivated = false
        s.setActive(false, notifyOthers: true)      // completeNarration (session already inactive)
        return decision
    }

    /// Counts every `setCategory` and `setActive`. Under the long-form category the route is the
    /// long-form one; under any other it is the app session's own (docs: may stay local).
    @MainActor final class CountingSession: DJAudioSessionPort {
        enum Call: Equatable { case setCategory(DJSessionConfig.Policy, UInt), setActive(Bool, notify: Bool) }
        var calls: [Call] = []
        var longForm: [LongFormPortType]
        var local: [LongFormPortType]
        var appActivated = false
        private var policy: DJSessionConfig.Policy = .default

        init(longForm: [LongFormPortType], local: [LongFormPortType]) {
            self.longForm = longForm
            self.local = local
        }

        /// Fry's B1: the next `failNormal` `.normal` sets and `failLongForm` `.airPlayGap` sets throw
        /// (still counted as calls; the category does not change).
        var failNormal = 0
        var failLongForm = 0

        var currentOutputs: [LongFormPortType] { policy == .longFormAudio ? longForm : local }
        @discardableResult
        func setCategory(_ config: DJSessionConfig) -> Bool {
            calls.append(.setCategory(config.policy, config.options.rawValue))
            if config.policy == .longFormAudio, failLongForm > 0 { failLongForm -= 1; return false }
            if config.policy == .default, config.options.contains(.mixWithOthers), failNormal > 0 { failNormal -= 1; return false }
            policy = config.policy
            return true
        }
        func setActive(_ active: Bool, notifyOthers: Bool) { calls.append(.setActive(active, notify: notifyOthers)) }

        /// Today's `TalkoverAudioSession` steps (4a2537b2), as calls.
        func apply(_ step: TalkoverSessionStep) {
            switch step {
            case .deactivate(let notify): setActive(false, notifyOthers: notify)
            case .setDuckCategory: setCategory(.talkoverDuck)
            case .activate: setActive(true, notifyOthers: false)
            case .restoreCategory: setCategory(.normal)
            }
        }
    }

    private func prepared(talkOverEnabled: @escaping @Sendable () -> Bool) async throws -> PreparedDJBreak {
        let main = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "A short main segment.",
                                estimatedSeconds: 2, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        let closing = NarrationCue(id: UUID(), order: 1, group: -1, kind: .transition, text: "Here's Song one.",
                                   estimatedSeconds: 1, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        var b = DJBreak(afterTrack: 0, cues: [main, closing],
                        attributions: [main.id: .presenter, closing.id: .trackMetadata(trackIDs: ["t1"])])
        b.talkOverCueID = closing.id
        let voice = FixedVoice(seconds: [main.text: 5, closing.text: 2])
        let route = VoiceRoute(providerID: "device", provider: voice, voice: VoiceProfile(id: "standard", name: "Host"))
        let renderer = VoiceRenderer(routes: [route], budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", talkOverEnabled: talkOverEnabled)
        let done = AsyncStream<Void>.makeStream()
        await preparer.observe { event in
            switch event {
            case .prepared, .skipped: done.continuation.yield()
            case .preparing: break
            }
        }
        await preparer.prepare(b, deadline: .seconds(5), onDeviceOnly: true)
        for await _ in done.stream { break }
        guard case .ready(let ready) = await preparer.takeBreak(afterTrack: 0) else {
            XCTFail("the break should prepare")
            throw CancellationError()
        }
        return ready
    }

    private struct FixedVoice: VoiceProvider {
        let seconds: [String: Double]
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            let plain = SpeechDelivery.plainText(fromSSML: text)
            return VoiceArtifact(data: Data(plain.utf8), durationSeconds: seconds[plain] ?? 1,
                                 billableUnits: 0, provider: "device", cacheKey: nil)
        }
    }

    private final class FlagTransport: HTTPTransport, @unchecked Sendable {
        let status: Int, body: String, error: Bool
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { seen } }
        init(status: Int = 200, body: String = "", error: Bool = false) { self.status = status; self.body = body; self.error = error }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { seen.append(request) }
            if error { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func coreSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AeroDJCore/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text between `signature`'s opening brace and its matching closing brace.
    private func body(_ source: String, _ signature: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "missing \(signature)")
        let open = try XCTUnwrap(source.range(of: "{", range: start.upperBound..<source.endIndex))
        var depth = 1
        var i = open.upperBound
        while i < source.endIndex {
            let c = source[i]
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { break } }
            i = source.index(after: i)
        }
        return String(source[open.upperBound..<i])
    }
}
