import Foundation

/// Scratch files for on-device speech renders. They hold spoken personal audio, so:
/// - they live only in a dedicated directory (`tmp/aerodj-speech/`) with a recognizable prefix;
/// - `withFile` deletes the file on every path (success, error, cancellation);
/// - `sweep()` at launch removes anything a crash or kill left behind.
public struct SpeechTempFiles: Sendable {
    public static let prefix = "aerodj-tts-"
    public static let shared = SpeechTempFiles()

    public let directory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aerodj-speech", isDirectory: true)) {
        self.directory = directory
    }

    /// A new, unique file URL in `directory` (created if needed).
    public func makeURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(Self.prefix)\(UUID().uuidString).caf", isDirectory: false)
    }

    /// Deletes everything in `directory`. Returns how many entries were removed.
    @discardableResult
    public func sweep() -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.reduce(0) { count, url in (try? FileManager.default.removeItem(at: url)) != nil ? count + 1 : count }
    }

    /// Runs `body` with a fresh temp file URL and always deletes the file afterwards.
    public func withFile<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = try makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }
}
