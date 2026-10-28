import XCTest
@testable import AeroDJCore

final class PhononSpeechSelectionTests: XCTestCase {
    private let cueToken = "ZEBRA-CUE-TOKEN"
    private let voice = VoiceProfile(id: PhononModelPin.voiceID, name: PhononModelPin.voiceID)

    func testFlagDefaultsOffAndStaysOnAVSpeechEvenWhenTheModelIsReady() {
        let suite = "phonon-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertFalse(PhononSpeechSelection.isFlagEnabled(defaults: defaults))
        let decision = PhononSpeechSelection.decide(flagEnabled: false, runtimeAvailable: true, model: .ready)
        XCTAssertEqual(decision.status, .disabled)
        XCTAssertEqual(decision.providerIDs, ["avspeech"])
        XCTAssertFalse(decision.attemptsPhonon)
        XCTAssertFalse(decision.providerIDs.contains { PhononSpeechSelection.isPaidProvider($0) })
    }

    func testRuntimeAndModelFailuresNeverSelectAPaidProvider() {
        let statuses: [PhononModelStatus] = [
            .disabled, .unsupportedRuntime, .missing, .downloadFailed, .hashMismatch,
            .rejectedBundle, .loadFailed, .voiceMissing, .ready,
        ]
        XCTAssertEqual(PhononModelPin.paidProviderIDs, BetaVoicePolicy.disabledProviderIDs)
        XCTAssertFalse(BetaVoicePolicy.paidProvidersEnabled)
        XCTAssertEqual(BetaVoicePolicy.paidSpendAllowedMicrodollars, 0)
        for flag in [false, true] {
            for runtime in [false, true] {
                for status in statuses {
                    let decision = PhononSpeechSelection.decide(flagEnabled: flag, runtimeAvailable: runtime, model: status)
                    XCTAssertEqual(decision.providerIDs.last, PhononModelPin.fallbackProviderID)
                    XCTAssertTrue(decision.providerIDs.allSatisfy { !PhononSpeechSelection.isPaidProvider($0) })
                    if flag && runtime {
                        XCTAssertEqual(decision.providerIDs, [PhononModelPin.providerID, "avspeech"])
                        XCTAssertTrue(decision.attemptsPhonon)
                    } else {
                        XCTAssertEqual(decision.providerIDs, ["avspeech"])
                        XCTAssertFalse(decision.attemptsPhonon)
                    }
                    if !flag {
                        XCTAssertEqual(decision.status, .disabled)
                    } else if !runtime {
                        XCTAssertEqual(decision.status, .unsupportedRuntime)
                    }
                }
            }
        }
        let coerced = PhononSpeechSelection.decide(flagEnabled: true, runtimeAvailable: true, model: .disabled)
        XCTAssertEqual(coerced.status, .missing)
    }

    func testBundleDigestMatchRequiresThePinnedHashAndSize() throws {
        XCTAssertEqual(PhononBundleDigest.verdict(byteCount: nil, sha256: nil), .missing)
        XCTAssertEqual(PhononBundleDigest.verdict(byteCount: PhononModelPin.bundleByteCount, sha256: nil), .missing)
        XCTAssertEqual(PhononBundleDigest.verdict(byteCount: nil, sha256: PhononModelPin.bundleSHA256), .missing)
        XCTAssertEqual(PhononBundleDigest.verdict(byteCount: 1, sha256: PhononModelPin.bundleSHA256), .mismatch)
        XCTAssertEqual(PhononBundleDigest.verdict(byteCount: PhononModelPin.bundleByteCount, sha256: String(repeating: "ab", count: 32)), .mismatch)
        XCTAssertEqual(
            PhononBundleDigest.verdict(byteCount: PhononModelPin.bundleByteCount, sha256: PhononModelPin.bundleSHA256.uppercased()),
            .match)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phonon-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try PhononBundleDigest.sha256Hex(ofFile: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("phonon-empty-\(UUID().uuidString)")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertEqual(try PhononBundleDigest.sha256Hex(ofFile: empty), SHA256Digest.hex(""))
    }

    func testDownloadURLIsThePinned31mBundleAndRejects40mMainAndTokens() {
        let url = PhononModelPin.bundleURL
        XCTAssertTrue(PhononModelPin.allowsDownload(url))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.user)
        XCTAssertEqual(PhononModelPin.weightsLicense, "apache-2.0")
        XCTAssertEqual(PhononModelPin.weightsRepository, "gradium/phonon-31m-en")
        XCTAssertNotEqual(PhononModelPin.weightsCommit, "main")
        XCTAssertEqual(PhononModelPin.weightsCommit.count, 40)
        XCTAssertEqual(PhononModelPin.bundleSHA256.count, 64)
        XCTAssertFalse(PhononModelPin.bundleURLString.contains("40m"))
        XCTAssertFalse(PhononModelPin.allowsDownload(PhononModelPin.weightsRevisionURL), "the weights page is not the download")
        XCTAssertTrue(PhononModelPin.weightsRevisionURL.absoluteString.contains(PhononModelPin.weightsCommit))
        let rejected = [
            "http://github.com/gradium-ai/xn-ptts/releases/download/v0.5.0/phonon-31m-en-coreml.zip",
            PhononModelPin.bundleURLString + "?token=secret",
            PhononModelPin.bundleURLString + "#frag",
            "https://user:token@github.com/gradium-ai/xn-ptts/releases/download/v0.5.0/phonon-31m-en-coreml.zip",
            "https://github.com/gradium-ai/xn-ptts/releases/download/v0.4.0/phonon-31m-en-coreml.zip",
            "https://huggingface.co/gradium/phonon-31m-en/resolve/main/phonon-31m-en-coreml.zip",
            "https://huggingface.co/gradium/phonon-40m-en/resolve/8acf8881a96315724c72ed3aad2a0900d1b230ba/model.safetensors",
            "https://huggingface.co/gradium/phonon-40m-multilingual/resolve/main/model.safetensors",
        ]
        for raw in rejected {
            XCTAssertFalse(PhononModelPin.allowsDownload(URL(string: raw)!), raw)
        }
    }

    func testSourceJSONMustBeThe31mExportCommit() {
        let accepted = """
        {"model":"\(PhononModelPin.sourceModel)","weights":"\(PhononModelPin.sourceWeights)","voices":"\(PhononModelPin.voicesSource)"}
        """
        XCTAssertTrue(PhononModelPin.acceptsSourceJSON(Data(accepted.utf8)))
        let pretty = """
        {
          "model": "\(PhononModelPin.sourceModel)",
          "weights": "model.safetensors",
          "voices": "\(PhononModelPin.voicesSource)"
        }
        """
        XCTAssertTrue(PhononModelPin.acceptsSourceJSON(Data(pretty.utf8)))
        let rejected = [
            #"{"model":"hf://gradium/phonon-40m-en@8acf8881a96315724c72ed3aad2a0900d1b230ba","weights":"model.safetensors","voices":"\#(PhononModelPin.voicesSource)"}"#,
            #"{"model":"hf://gradium/phonon-31m-en@main","weights":"model.safetensors","voices":"\#(PhononModelPin.voicesSource)"}"#,
            #"{"model":"hf://gradium/phonon-40m-multilingual@8acf8881a96315724c72ed3aad2a0900d1b230ba","weights":"model.safetensors","voices":"\#(PhononModelPin.voicesSource)"}"#,
            #"{"model":"\#(PhononModelPin.sourceModel)","weights":"model.safetensors","voices":"hf://gradium/phonon-voices@main"}"#,
            #"{"weights":"model.safetensors"}"#,
            "not-json",
        ]
        for raw in rejected {
            XCTAssertFalse(PhononModelPin.acceptsSourceJSON(Data(raw.utf8)), raw)
        }
    }

    func testZipEntriesStayInsideThe31mBundle() {
        XCTAssertEqual(PhononBundlePath.relativePath(forZipEntry: "phonon-31m-en-coreml/"), "")
        XCTAssertEqual(PhononBundlePath.relativePath(forZipEntry: "phonon-31m-en-coreml/bundle.json"), "bundle.json")
        XCTAssertEqual(PhononBundlePath.relativePath(forZipEntry: "phonon-31m-en-coreml/voices/Everly.safetensors"), "voices/Everly.safetensors")
        XCTAssertEqual(PhononBundlePath.relativePath(forZipEntry: "phonon-31m-en-coreml/source.json"), "source.json")
        let rejected = [
            "../etc/passwd",
            "phonon-31m-en-coreml/../../outside",
            "/tmp/phonon-31m-en-coreml/bundle.json",
            "phonon-31m-en-coreml/voices/../source.json",
            "phonon-40m-en/bundle.json",
            "phonon-31m-en-coreml/voices/..\\secret",
            "other/bundle.json",
        ]
        for entry in rejected {
            XCTAssertNil(PhononBundlePath.relativePath(forZipEntry: entry), entry)
        }
    }

    func testWAVHeaderIs24kHzMonoPCM16() {
        let wav = PhononWAV.encodePCM16(samples: [0, 1, -1, .nan])
        XCTAssertEqual(PhononWAV.durationSeconds(wav: wav), 4 / 24_000)
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
        XCTAssertNil(PhononWAV.durationSeconds(wav: Data("nope".utf8)))
        XCTAssertTrue(PhononWAV.encodePCM16(samples: []).isEmpty)
        XCTAssertTrue(PhononWAV.encodePCM16(samples: [Float](repeating: 0, count: PhononWAV.sampleRate * (PhononWAV.maxSeconds + 1))).isEmpty)
        let bytes = [UInt8](wav)
        // data samples: 0, max, min, nan->0
        XCTAssertEqual(Int16(bitPattern: UInt16(bytes[44]) | UInt16(bytes[45]) << 8), 0)
        XCTAssertEqual(Int16(bitPattern: UInt16(bytes[46]) | UInt16(bytes[47]) << 8), 32_767)
        XCTAssertEqual(Int16(bitPattern: UInt16(bytes[48]) | UInt16(bytes[49]) << 8), -32_768)
    }

    func testUnreadyModelFallsBackToAVSpeechWithZeroPaidSpend() async {
        let failures: [PhononModelStatus] = [.missing, .hashMismatch, .downloadFailed, .rejectedBundle, .loadFailed, .voiceMissing]
        for status in failures {
            let decision = PhononSpeechSelection.decide(flagEnabled: true, runtimeAvailable: true, model: status)
            let paid = PhononCallCount(id: "cartesia")
            let phonon = ThrowingVoice()
            let device = PhononCallCount(id: "avspeech")
            let routes = routes(for: decision, phonon: phonon, device: device)
            XCTAssertFalse(routes.contains { PhononSpeechSelection.isPaidProvider($0.providerID) })
            let budget = VoiceBudget(dailyCapMicrodollars: VoiceBetaDefaults.paidDailyCapMicrodollars)
            let renderer = VoiceRenderer(routes: routes, budget: budget, cache: InMemoryAudioCache())
            let rendered = await renderer.render(cue(cueToken), userID: "listener", stationID: "default")
            let clip = try! rendered.get()
            XCTAssertEqual(clip.audio.providerID, "avspeech", "\(status)")
            XCTAssertEqual(clip.attempts.map(\.providerID), ["phonon", "avspeech"])
            if case .failed(let message) = clip.attempts[0].result {
                XCTAssertFalse(message.contains(cueToken), "diagnostics included cue text: \(message)")
            } else {
                XCTFail("phonon should fail closed for \(status)")
            }
            let deviceCalls = await device.calls
            let paidCalls = await paid.calls
            let spent = await budget.committed(userID: "listener")
            let reserved = await budget.reserve(userID: "listener", microdollars: 1)
            XCTAssertEqual(deviceCalls, 1)
            XCTAssertEqual(paidCalls, 0, "paid provider was not in the chain")
            XCTAssertEqual(spent, 0)
            XCTAssertNil(reserved)
        }
    }

    func testReadyPhononIsUsedAndCachedUnderTheSevenDayPurgeRules() async {
        let decision = PhononSpeechSelection.decide(flagEnabled: true, runtimeAvailable: true, model: .ready)
        let phonon = PhononCallCount(id: PhononModelPin.providerID)
        let device = PhononCallCount(id: "avspeech")
        let clock = PhononTestClock()
        let cache = InMemoryAudioCache(maxAge: AudioCacheRetention.maximum, now: { clock.now })
        let budget = VoiceBudget(dailyCapMicrodollars: 0)
        let renderer = VoiceRenderer(routes: routes(for: decision, phonon: phonon, device: device), budget: budget, cache: cache)
        let source = UUID()
        let rendered = await renderer.render(cue(cueToken, source: source), userID: "listener", stationID: "default")
        let clip = try! rendered.get()
        XCTAssertEqual(clip.audio.providerID, PhononModelPin.providerID)
        XCTAssertEqual(clip.audio.voiceID, PhononModelPin.voiceID)
        let deviceCalls = await device.calls
        let spent = await budget.committed(userID: "listener")
        XCTAssertEqual(deviceCalls, 0)
        XCTAssertEqual(spent, 0)
        let stored = await cache.audio(for: clip.cacheKey)
        XCTAssertEqual(stored?.providerID, PhononModelPin.providerID)
        await cache.purge(sourceItemIDs: [source])
        let purged = await cache.audio(for: clip.cacheKey)
        XCTAssertNil(purged, "consent purge removes a phonon clip from the shared cache")

        let again = await renderer.render(cue("other line", source: source), userID: "listener", stationID: "default")
        let second = try! again.get()
        clock.now += AudioCacheRetention.maximum
        let atLimit = await cache.audio(for: second.cacheKey)
        XCTAssertNotNil(atLimit)
        clock.now += 1
        let past = await cache.audio(for: second.cacheKey)
        XCTAssertNil(past, "phonon clips expire with the 7-day cap")
    }

    func testPhononRouteIsFreeUnderBetaPolicy() {
        let route = VoiceRoute(providerID: PhononModelPin.providerID, provider: ThrowingVoice(), voice: voice,
                               microdollarsPerThousandCharacters: 0, acceptsSSML: false)
        XCTAssertFalse(route.isPaid)
        XCTAssertTrue(BetaVoicePolicy.problems(routes: [route], dailyCapMicrodollars: 0).isEmpty)
        let paid = VoiceRoute(providerID: "elevenlabs", provider: ThrowingVoice(), voice: voice, microdollarsPerThousandCharacters: 1)
        XCTAssertFalse(BetaVoicePolicy.problems(routes: [paid], dailyCapMicrodollars: 0).isEmpty)
    }

    private func routes(for decision: PhononSpeechDecision, phonon: ThrowingVoice, device: PhononCallCount) -> [VoiceRoute] {
        decision.providerIDs.map { id in
            let provider: any VoiceProvider = id == PhononModelPin.providerID ? phonon : device
            return VoiceRoute(providerID: id, provider: provider, voice: voice, microdollarsPerThousandCharacters: 0,
                              timeout: .seconds(8), acceptsSSML: false)
        }
    }

    private func routes(for decision: PhononSpeechDecision, phonon: PhononCallCount, device: PhononCallCount) -> [VoiceRoute] {
        decision.providerIDs.map { id in
            let provider: any VoiceProvider = id == PhononModelPin.providerID ? phonon : device
            return VoiceRoute(providerID: id, provider: provider, voice: voice, microdollarsPerThousandCharacters: 0,
                              timeout: .seconds(8), acceptsSSML: false)
        }
    }

    private func cue(_ text: String, source: UUID? = nil) -> NarrationCue {
        NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: text, estimatedSeconds: 4,
                     maxSeconds: 30, sourceItemID: source, source: source == nil ? nil : .calendar,
                     provenance: source == nil ? nil : "test")
    }
}

private final class PhononTestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private actor PhononCallCount: VoiceProvider {
    let id: String
    private(set) var calls = 0
    init(id: String) { self.id = id }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        calls += 1
        return VoiceArtifact(data: Data("pcm".utf8), durationSeconds: 1.5, billableUnits: 0, provider: id, cacheKey: nil)
    }
}

private struct ThrowingVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        throw PhononTestFailure.notReady
    }
}

private enum PhononTestFailure: Error, CustomStringConvertible {
    case notReady
    var description: String { "phonon.missing" }
}
