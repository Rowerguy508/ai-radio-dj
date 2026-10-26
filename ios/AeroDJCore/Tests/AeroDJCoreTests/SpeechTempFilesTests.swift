import XCTest
@testable import AeroDJCore

final class SpeechTempFilesTests: XCTestCase {
    private var temp: SpeechTempFiles!

    private var legacyRoot: URL!

    override func setUp() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aerodj-speech-test-\(UUID().uuidString)", isDirectory: true)
        legacyRoot = root   // stands in for tmp/ itself
        temp = SpeechTempFiles(directory: root.appendingPathComponent("aerodj-speech", isDirectory: true), legacyDirectory: root)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: legacyRoot) }

    private var leftovers: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: temp.directory.path)) ?? []
    }

    func testDefaultLocationIsDedicatedDirectoryWithPrefix() throws {
        let shared = SpeechTempFiles()
        XCTAssertEqual(shared.directory.lastPathComponent, "aerodj-speech")
        XCTAssertEqual(shared.directory.deletingLastPathComponent().standardizedFileURL,
                       FileManager.default.temporaryDirectory.standardizedFileURL)
        let url = try temp.makeURL()
        XCTAssertTrue(url.lastPathComponent.hasPrefix(SpeechTempFiles.prefix))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, temp.directory.standardizedFileURL)
    }

    func testLeftoverFromACrashIsRemovedAtStartup() throws {
        let leftover = try temp.makeURL()
        try Data("spoken personal audio".utf8).write(to: leftover)
        try Data("stray".utf8).write(to: temp.directory.appendingPathComponent("other.tmp"))
        XCTAssertEqual(temp.sweep(), 2)
        XCTAssertEqual(leftovers, [])
        XCTAssertEqual(temp.sweep(), 0, "sweeping an empty or missing directory is a no-op")
    }

    func testSuccessPathLeavesNoFile() async throws {
        let size = try await temp.withFile { url -> Int in
            try Data("pcm".utf8).write(to: url)
            return try Data(contentsOf: url).count
        }
        XCTAssertEqual(size, 3)
        XCTAssertEqual(leftovers, [])
    }

    func testErrorPathLeavesNoFile() async throws {
        do {
            _ = try await temp.withFile { url -> Int in
                try Data("partial".utf8).write(to: url)
                throw URLError(.cannotDecodeContentData)
            }
            XCTFail("expected the render error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotDecodeContentData)
        }
        XCTAssertEqual(leftovers, [])
    }

    func testCancelPathLeavesNoFile() async throws {
        let temp = self.temp!
        let started = expectation(description: "render started")
        let task = Task {
            try await temp.withFile { url in
                try Data("partial".utf8).write(to: url)
                try await SpeechRenderCompletion().wait(start: { started.fulfill() })   // never signalled
            }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(leftovers.count, 1, "file exists mid-render")
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(leftovers, [])
    }

    /// Deadline path: the route timeout cancels the render; its temp file is still deleted.
    func testDeadlinePathLeavesNoFile() async throws {
        struct TempFileVoice: VoiceProvider {
            let temp: SpeechTempFiles
            let cleanedUp: XCTestExpectation
            func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
                defer { cleanedUp.fulfill() }   // runs after withFile has deleted the file
                return try await temp.withFile { url in
                    try Data("partial".utf8).write(to: url)
                    try await SpeechRenderCompletion().wait(start: {})   // iOS never signals
                    return VoiceArtifact(data: Data(), durationSeconds: 0, billableUnits: 0, provider: "avspeech", cacheKey: nil)
                }
            }
        }
        let cleanedUp = expectation(description: "render unwound")
        let route = VoiceRoute(providerID: "avspeech", provider: TempFileVoice(temp: temp, cleanedUp: cleanedUp),
                               voice: VoiceProfile(id: "host", name: "Host"), timeout: .milliseconds(50), acceptsSSML: true)
        let renderer = VoiceRenderer(routes: [route], budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let cue = NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: "That was Song 1.", estimatedSeconds: 2,
                               maxSeconds: 12, sourceItemID: nil, source: nil, provenance: nil)
        let result = await renderer.render(cue, userID: "u", stationID: "s")
        guard case .failure(let failure) = result else { return XCTFail("deadline must fail the render") }
        XCTAssertEqual(failure.attempts.map(\.result), [.timedOut])
        await fulfillment(of: [cleanedUp], timeout: 2)
        XCTAssertEqual(leftovers, [])
    }

    // Atlas #77 (low): builds up to 5dbf6d9 wrote tmp/aerodj-tts-*.caf directly in tmp.
    func testLaunchSweepRemovesLegacyRootTempFilesOnly() throws {
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacy = legacyRoot.appendingPathComponent("aerodj-tts-\(UUID().uuidString).caf")
        let unrelated = ["other.caf", "aerodj-tts-notes.txt", "my-aerodj-tts-x.caf"].map { legacyRoot.appendingPathComponent($0) }
        for url in [legacy] + unrelated { try Data("x".utf8).write(to: url) }
        temp.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy speech temp file removed")
        for url in unrelated { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) untouched") }
        XCTAssertEqual(SpeechTempFiles().legacyDirectory.standardizedFileURL,
                       FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    func testLegacySweepDeletesOnlyPrefixedCafFilesAndLeavesDecoys() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacy = ["aerodj-tts-\(UUID().uuidString).caf", "aerodj-tts-old.caf"].map { legacyRoot.appendingPathComponent($0) }
        let decoyFiles = ["other.caf", "aerodj-tts.txt", "aerodj-tts-x.caf.bak", "AeroDJ-TTS-upper.caf", "xaerodj-tts-1.caf"]
            .map { legacyRoot.appendingPathComponent($0) }
        let subfolder = legacyRoot.appendingPathComponent("aerodj-tts-folder.caf", isDirectory: true)  // folder named like a legacy file
        let plainFolder = legacyRoot.appendingPathComponent("cache", isDirectory: true)
        let nested = [subfolder, plainFolder].map { $0.appendingPathComponent("aerodj-tts-nested.caf") }  // never recurse
        for dir in [subfolder, plainFolder] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        for url in legacy + decoyFiles + nested { try Data("x".utf8).write(to: url) }

        XCTAssertEqual(temp.sweep(), legacy.count, "only the legacy files are counted")

        for url in legacy { XCTAssertFalse(fm.fileExists(atPath: url.path), "\(url.lastPathComponent) removed") }
        for url in decoyFiles + [subfolder, plainFolder] + nested {
            XCTAssertTrue(fm.fileExists(atPath: url.path), "\(url.lastPathComponent) untouched")
        }
    }
}
