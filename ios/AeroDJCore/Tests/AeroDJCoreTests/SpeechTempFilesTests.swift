import XCTest
@testable import AeroDJCore

final class SpeechTempFilesTests: XCTestCase {
    private var temp: SpeechTempFiles!

    override func setUp() {
        temp = SpeechTempFiles(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("aerodj-speech-test-\(UUID().uuidString)", isDirectory: true))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: temp.directory) }

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
}
