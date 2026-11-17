import Foundation
import XCTest
@testable import AeroDJCore

/// #526 S0a (-Echo): the DEBUG-only AirPlay duck spike. The source checks (like #547's
/// `StationRatingsInAppTests` hold check) pin that every spike symbol compiles only in DEBUG
/// and that no setting, launch argument or URL reaches it. Device: NOT TESTED.
final class AirPlayDuckSpikeTests: XCTestCase {
    private static var ios: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func swiftFiles(under dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = e?.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    /// `#if DEBUG` nesting depth before each line (other `#if` blocks counted, not as DEBUG).
    private static func debugDepths(_ lines: [String]) -> [Int] {
        var stack: [Bool] = []
        var depths: [Int] = []
        for line in lines {
            depths.append(stack.filter { $0 }.count)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if ") { stack.append(t == "#if DEBUG") }
            else if t.hasPrefix("#endif"), !stack.isEmpty { stack.removeLast() }
        }
        return depths
    }

    /// Every line in app and Core sources that names the spike sits inside `#if DEBUG`.
    func testEverySpikeSymbolCompilesOnlyInDebug() throws {
        let roots = [Self.ios.appendingPathComponent("AeroDJ"),
                     Self.ios.appendingPathComponent("AeroDJCore/Sources")]
        var hits = 0
        for root in roots {
            for file in Self.swiftFiles(under: root) {
                let text = try String(contentsOf: file, encoding: .utf8)
                guard text.contains("AirPlayDuckSpike") else { continue }
                let lines = text.components(separatedBy: "\n")
                let depths = Self.debugDepths(lines)
                for (i, line) in lines.enumerated() where line.contains("AirPlayDuckSpike") {
                    hits += 1
                    XCTAssertGreaterThanOrEqual(depths[i], 1, "\(file.lastPathComponent):\(i + 1) is outside #if DEBUG")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(hits, 10, "the spike files and the Settings row were found")
    }

    /// Both spike files are wrapped whole in `#if DEBUG`, and none of them reads a setting, a
    /// launch argument, an environment variable or a URL. The Settings row is the only entry.
    func testTheSpikeHasNoSettingLaunchArgumentOrURLAndOneEntry() throws {
        let files = [Self.ios.appendingPathComponent("AeroDJ/AirPlayDuckSpike.swift"),
                     Self.ios.appendingPathComponent("AeroDJCore/Sources/AeroDJCore/Playback/AirPlayDuckSpike.swift")]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let first = try XCTUnwrap(code.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            XCTAssertEqual(first, "#if DEBUG", file.lastPathComponent)
            XCTAssertEqual(code.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "#endif", file.lastPathComponent)
            let body = code.joined(separator: "\n")
            for forbidden in ["UserDefaults", "forKey", "ProcessInfo.processInfo.arguments", "environment[", "URL(", "openURL",
                              "Cartesia", "Dessa", "URLSession"] {
                XCTAssertFalse(body.contains(forbidden), "\(file.lastPathComponent) must not use \(forbidden)")
            }
        }
        let app = Self.swiftFiles(under: Self.ios.appendingPathComponent("AeroDJ"))
        let entries = try app.filter { try String(contentsOf: $0, encoding: .utf8).contains("AirPlayDuckSpikeView()") }
        XCTAssertEqual(entries.map(\.lastPathComponent), ["SettingsView.swift"], "one developer entry")
        let settings = try String(contentsOf: Self.ios.appendingPathComponent("AeroDJ/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("if !isTestStation {"), "live DEBUG builds only, never captures or fixture runs")
    }

    /// One clip, one player, and the clip stops before the session is released.
    func testTheAppRunnerPlaysOneClipAndStopsItBeforeReleasingTheSession() throws {
        let text = try String(contentsOf: Self.ios.appendingPathComponent("AeroDJ/AirPlayDuckSpike.swift"), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "AVAudioPlayer(data:").count - 1, 1, "exactly one clip player")
        let stop = try XCTUnwrap(text.range(of: "player?.stop()"))
        let release = try XCTUnwrap(text.range(of: "setActive(false, options: .notifyOthersOnDeactivation)"))
        XCTAssertLessThan(stop.lowerBound, release.lowerBound)
        XCTAssertTrue(text.contains("AirPlayDuckSpikeGate.refusal("), "the gate runs before any session call")
        let gate = try XCTUnwrap(text.range(of: "AirPlayDuckSpikeGate.refusal("))
        let firstSessionCall = try XCTUnwrap(text.range(of: "session.setCategory("))
        XCTAssertLessThan(gate.lowerBound, firstSessionCall.lowerBound)
        for forbidden in ["pausePlayerForBreak", "resumeIfAllowed", ".skip(", "player.pause()", "ApplicationMusicPlayer.shared.play",
                          "ApplicationMusicPlayer.shared.pause"] {
            XCTAssertFalse(text.contains(forbidden), "the spike never drives the music: \(forbidden)")
        }
    }

    #if DEBUG
    func testTheGateNeverRunsDuringABreakOrNearASongEnd() {
        func refusal(running: Bool = false, airPlay: Bool = true, playing: Bool = true, idle: Bool = true,
                     remaining: Double? = 120) -> AirPlayDuckSpikeRefusal? {
            AirPlayDuckSpikeGate.refusal(running: running, onAirPlay: airPlay, musicPlaying: playing, djIdle: idle,
                                         remainingSeconds: remaining)
        }
        XCTAssertNil(refusal())
        XCTAssertEqual(refusal(running: true), .alreadyRunning)
        XCTAssertEqual(refusal(idle: false), .djBusy)
        XCTAssertEqual(refusal(airPlay: false), .notOnAirPlay)
        XCTAssertEqual(refusal(playing: false), .musicNotPlaying)
        XCTAssertEqual(refusal(remaining: 29.9), .tooCloseToSongEnd)
        XCTAssertEqual(refusal(remaining: nil), .tooCloseToSongEnd)
        XCTAssertNil(refusal(remaining: 30))
        XCTAssertGreaterThan(AirPlayDuckSpikeGate.minimumRemainingSeconds,
                             TalkoverConfig().maxOutroOverlap + TalkoverConfig().armLead + AirPlayDuckSpikeClip.seconds + 2,
                             "past the talk-over arm window plus one run")
    }

    func testTheVariantsAreTodaysSessionShapes() {
        XCTAssertEqual(AirPlayDuckSpikeVariant.duckOthers.config, .talkoverDuck)
        XCTAssertEqual(AirPlayDuckSpikeVariant.longFormAudio.config, .airPlayGap)
        XCTAssertEqual(AirPlayDuckSpikeVariant.mixWithOthers.config, .normal)
        XCTAssertEqual(AirPlayDuckSpikeVariant.duckOthers.sessionDescription,
                       "category=playback mode=default policy=default options=0x2")
        XCTAssertEqual(AirPlayDuckSpikeVariant.longFormAudio.sessionDescription,
                       "category=playback mode=default policy=longFormAudio options=0x0")
    }

    func testTheMusicOutcomeIsClassifiedFromStatusSamples() {
        XCTAssertEqual(AirPlayDuckSpikeMusicOutcome.classify(["playing", "playing"]), .keptPlaying)
        XCTAssertEqual(AirPlayDuckSpikeMusicOutcome.classify(["playing", "paused"]), .paused)
        XCTAssertEqual(AirPlayDuckSpikeMusicOutcome.classify(["playing", "stopped", "paused"]), .stopped)
        XCTAssertEqual(AirPlayDuckSpikeMusicOutcome.classify(["interrupted", "paused"]), .interrupted)
        XCTAssertEqual(AirPlayDuckSpikeMusicOutcome.classify([]), .unknown)
        var report = AirPlayDuckSpikeReport(variant: .longFormAudio)
        report.musicDuring = ["playing"]
        report.interruptionBegan = true
        XCTAssertEqual(report.musicOutcome, .interrupted, "an interruption notification wins")
    }

    func testTheLogHasCodesAndPortTypesOnly() {
        var report = AirPlayDuckSpikeReport(variant: .duckOthers)
        report.routeBefore = [.airPlay]
        report.routeDuring = [.airPlay, .builtInSpeaker]
        report.routeAfter = [.airPlay]
        report.musicBefore = "playing"
        report.musicDuring = ["playing", "playing"]
        report.musicAfter = "playing"
        report.setCategoryOK = true
        report.setActiveOK = true
        report.activateMs = 42
        report.clipStarted = true
        report.clipFinishedOK = true
        report.restoreOK = true
        XCTAssertEqual(report.lines, [
            "S0a variant=duckOthers category=playback mode=default policy=default options=0x2",
            "S0a route before=airPlay during=airPlay+builtInSpeaker after=airPlay",
            "S0a session setCategory=1 setActive=1 activateMs=42 otherAudio=- silenceHint=-",
            "S0a music before=playing during=playing,playing after=playing outcome=keptPlaying",
            "S0a systemMusic before= during=",
            "S0a clip started=1 finished=1 interruption began=0 ended=0",
            "S0a routeChanges=none restore=1",
        ])
        var refused = AirPlayDuckSpikeReport(variant: .longFormAudio)
        refused.refusal = .djBusy
        XCTAssertEqual(refused.lines, ["S0a variant=longFormAudio refused=djBusy"])
    }

    func testTheClipIsOneTwoSecondMonoWAV() {
        let wav = AirPlayDuckSpikeClip.toneWAV()
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav.count, 44 + AirPlayDuckSpikeClip.sampleRate * 2 * 2, "2 s, 16-bit mono at 44.1 kHz")
        XCTAssertEqual(AirPlayDuckSpikeClip.seconds, 2)
    }
    #endif
}
