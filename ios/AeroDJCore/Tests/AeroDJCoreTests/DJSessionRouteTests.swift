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
        let defaults = try freshDefaults()
        XCTAssertTrue(DJAirPlayRouteFlag.isEnabled(defaults: defaults), "never fetched: on")
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
        let fresh = try freshDefaults()
        for t in [FlagTransport(status: 503, body: #"{"djAirPlayLongForm":false}"#),
                  FlagTransport(status: 200, body: "nope"), FlagTransport(error: true)] {
            let value = await DJAirPlayRouteFlag.refresh(transport: t, baseURL: base, defaults: fresh)
            XCTAssertTrue(value, "fail open")
        }
        XCTAssertTrue(DJAirPlayRouteFlag.isEnabled(defaults: fresh))
        // A fetched false kills it, and the request is a bare GET.
        let kill = FlagTransport(status: 200, body: #"{"djAirPlayLongForm":false}"#)
        let killed = await DJAirPlayRouteFlag.refresh(transport: kill, baseURL: base, defaults: fresh)
        XCTAssertFalse(killed)
        XCTAssertFalse(DJAirPlayRouteFlag.isEnabled(defaults: fresh))
        let request = try XCTUnwrap(kill.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://proxy.invalid/api/flags")
        XCTAssertNil(request.httpBody, "nothing is sent")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no token")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(DJAirPlayRouteFlag.request(baseURL: DJAirPlayRouteFlag.proxyBaseURL)?.url?.absoluteString,
                       "https://aerodj-tts.vercel.app/api/flags")
        // While killed, a failure keeps it killed; a fetched true lifts it.
        let stillKilled = await DJAirPlayRouteFlag.refresh(transport: FlagTransport(error: true), baseURL: base, defaults: fresh)
        XCTAssertFalse(stillKilled)
        let lifted = await DJAirPlayRouteFlag.refresh(transport: FlagTransport(status: 200, body: #"{"djAirPlayLongForm":true}"#),
                                                      baseURL: base, defaults: fresh)
        XCTAssertTrue(lifted)
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
        let defaults = try freshDefaults()
        let spy = FlagTransport(status: 200, body: #"{"djAirPlayLongForm":false}"#)
        let value = await DJAirPlayRouteFlag.refresh(transport: spy, baseURL: URL(string: "http://proxy.invalid")!, defaults: defaults)
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
        let plan = TalkoverPlan(mode: .outroOnly, introSkip: .noClosingLine, outroOverlap: 4, voiceStartAt: 196,
                                nextPlayAfterVoice: nil, nextAudibleAfterVoice: nil, unduckAfterVoice: 12,
                                startLatency: 0.8, voiceSeconds: 12)
        let decisions: [TalkoverDecision] = [.talkover(plan)] + TalkoverHardBreak.allCases.map { .hardBreak($0) }
        for planned in decisions {
            for route in LongFormRouteKind.allCases {
                for flag in [false, true] {
                    let checked = DJTalkoverRouteCheck.decide(planned, route: route, airPlayFlag: flag)
                    if planned.plan != nil, flag, route == .airPlay {
                        XCTAssertEqual(checked, .hardBreak(.airPlayRoute), "AirPlay mid-song: a gap break")
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
        let probe = try XCTUnwrap(take.range(of: "DJRouteSession.probeBeforeTalkover()"))
        let check = try XCTUnwrap(take.range(of: "DJTalkoverRouteCheck.decide(planned,"))
        let strip = try XCTUnwrap(take.range(of: "held = (k, DJTalkoverRouteCheck.gapBreak(from: h.prepared))"))
        let decide = try XCTUnwrap(take.range(of: "decide(decision, afterTrack: k)"))
        let run = try XCTUnwrap(take.range(of: "run = TalkoverRun(afterTrack: k, plan: plan)"))
        let duck = try XCTUnwrap(take.range(of: "interlude.duckForTalkover(afterTrack: k)"))
        XCTAssertLessThan(planner.lowerBound, probe.lowerBound)
        XCTAssertLessThan(probe.lowerBound, decide.lowerBound)
        XCTAssertLessThan(check.lowerBound, strip.lowerBound)
        XCTAssertLessThan(decide.lowerBound, run.lowerBound, "checked before the run exists")
        XCTAssertLessThan(run.lowerBound, duck.lowerBound, "and before the duck")
        XCTAssertTrue(take.contains("let decision = planned.plan == nil ? planned"), "a planned hard break is not probed")
        let source = try appSource("DJRouteSession.swift")
        let before = try body(source, "@MainActor static func probeBeforeTalkover()")
        XCTAssertTrue(before.hasPrefix("\n        guard DJAirPlayRouteFlag.isEnabled() else { return DJLongFormRouteState.shared.lastRoute }"),
                      "killed: nothing is touched")
        XCTAssertFalse(before.contains("fetch"), "a talk-over check never fetches")
        XCTAssertTrue(source.contains("transport: DJAirPlayRouteFlag.makeTransport()"), "the ephemeral transport")
        XCTAssertFalse(source.contains("URLSessionTransport()"), "never the shared session")
    }

    // MARK: Fetch gate (privacy)

    func testNoFetchOffAirPlayNoneBeforeTheFirstAirPlayGapBreakAndAtMostOnePerLaunch() {
        // Off AirPlay: never, at any probe, however many breaks.
        var offAirPlay = DJAirPlayFlagFetchGate()
        for route in LongFormRouteKind.allCases where route != .airPlay {
            for event in DJAirPlayFlagFetchGate.ProbeEvent.allCases {
                for _ in 0..<3 { XCTAssertFalse(offAirPlay.shouldFetch(route: route, at: event), "\(route) \(event)") }
            }
        }
        XCTAssertFalse(offAirPlay.fetched)
        // On AirPlay: not at song start (before the first gap break), then once at the first
        // AirPlay gap break, then never again this launch.
        var launch = DJAirPlayFlagFetchGate()
        for _ in 0..<3 { XCTAssertFalse(launch.shouldFetch(route: .airPlay, at: .songStart), "no fetch before the first gap break") }
        XCTAssertFalse(launch.shouldFetch(route: .bluetooth, at: .gapBreak))
        XCTAssertTrue(launch.shouldFetch(route: .airPlay, at: .gapBreak), "the first AirPlay gap break fetches")
        var later = 0
        for route in LongFormRouteKind.allCases {
            for event in DJAirPlayFlagFetchGate.ProbeEvent.allCases where launch.shouldFetch(route: route, at: event) { later += 1 }
        }
        XCTAssertEqual(later, 0, "at most one fetch per launch")
        // A new launch (a new gate) may fetch once again.
        var next = DJAirPlayFlagFetchGate()
        XCTAssertTrue(next.shouldFetch(route: .airPlay, at: .gapBreak))
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

    // MARK: DIAG rows

    func testEveryRouteKindPortTypeAndShapeHasATraceCode() {
        for r in LongFormRouteKind.allCases { XCTAssertNotNil(P0TraceCode(rawValue: r.rawValue), "\(r)") }
        for p in LongFormPortType.allCases { XCTAssertNotNil(P0TraceCode(rawValue: p.rawValue), "\(p)") }
        for s in DJSessionShape.allCases { XCTAssertNotNil(P0TraceCode(rawValue: s.rawValue), "\(s)") }
        XCTAssertNotNil(P0TraceCode(rawValue: TalkoverHardBreak.airPlayRoute.rawValue))
    }

    func testTheRouteRowsCarryPortTypesAndShapesOnly() {
        var trace = P0EventTrace()
        let probe = trace.sessionRouteProbe(route: .airPlay, ports: [.airPlay, .builtInSpeaker, .bluetoothA2DP], flag: true,
                                            talkoverAllowed: false, changed: true, at: 3)
        XCTAssertEqual(probe.event, .sessionRoute)
        XCTAssertEqual(probe.detail, "kind=probe route=airPlay port1=airPlay port2=builtInSpeaker ports=3 flag=1 allowed=0 changed=1")
        let shape = trace.sessionBreakShape(.longFormAirPlay, route: .airPlay, afterTrack: 4, at: 4)
        XCTAssertEqual(shape.detail, "kind=breakShape after=4 shape=longFormAirPlay route=airPlay")
        let skipped = trace.sessionRouteProbeSkipped(flag: true, at: 5)
        XCTAssertEqual(skipped.detail, "kind=probeSkipped flag=1")
        let fallback = trace.talkoverDecision(.hardBreak(.airPlayRoute), afterTrack: 4, at: 6)
        XCTAssertEqual(fallback.detail, "kind=decision after=4 mode=hardBreak reason=airPlayRoute")
        XCTAssertEqual(TalkoverLog.decision(afterTrack: 4, .hardBreak(.airPlayRoute)),
                       "talkover plan after=4 result=hardBreak reason=airPlayRoute")
    }

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
        // The only network call sits behind the gate, which only the gap break calls.
        XCTAssertEqual(source.components(separatedBy: "DJAirPlayRouteFlag.refresh(").count - 1, 1)
        let fetch = try body(source, "@MainActor private static func fetchFlagIfAllowed(route: LongFormRouteKind)")
        XCTAssertTrue(fetch.hasPrefix("\n        guard fetchGate.shouldFetch(route: route, at: .gapBreak) else { return }"))
        XCTAssertTrue(fetch.contains("DJAirPlayRouteFlag.refresh("))
        XCTAssertEqual(source.components(separatedBy: "fetchFlagIfAllowed(route:").count - 1, 2, "declared once, called once")
        let begin = try body(source, "@MainActor static func beginGapBreak(")
        XCTAssertTrue(begin.contains("fetchFlagIfAllowed(route: route)"))
        let song = try body(source, "@MainActor static func probeBeforeSong()")
        XCTAssertTrue(song.hasPrefix("\n        guard DJAirPlayRouteFlag.isEnabled() else { return }"), "killed: nothing at song start")
        XCTAssertFalse(song.contains("fetch"), "a song-start probe never fetches")
        let probing = try body(source, "@MainActor private static func probe(keepLongForm: Bool)")
        XCTAssertTrue(probing.contains("guard !TalkoverAudioSession.appActivated else {"), "never on an active session")
        XCTAssertTrue(probing.contains("return (DJLongFormRouteState.shared.lastRoute, false)"), "a skipped probe keeps today's session")
        XCTAssertTrue(probing.contains("policy: .longFormAudio, options: []"))
        XCTAssertTrue(source.contains("policy: .default, options: options)"), "the restore names the default policy")
        // Nothing else in the app fetches the switch.
        for file in ["MusicKitService.swift", "TalkoverCoordinator.swift", "InterludePlaybackAdapter.swift", "AppDependencies.swift"] {
            let other = try appSource(file)
            XCTAssertFalse(other.contains("DJAirPlayRouteFlag.refresh"), file)
            XCTAssertFalse(other.contains("fetchFlag"), file)
        }
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

    private func freshDefaults() throws -> UserDefaults {
        let name = "DJSessionRouteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
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
