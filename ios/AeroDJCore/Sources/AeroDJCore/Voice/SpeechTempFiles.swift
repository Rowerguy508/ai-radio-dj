import Foundation

/// Scratch files for on-device speech renders. They hold spoken personal audio, so:
/// - they live only in a dedicated directory (`tmp/aerodj-speech/`) with a recognizable prefix;
/// - `withFile` deletes the file on every path (success, error, cancellation);
/// - `sweep()` at launch removes anything a crash or kill left behind, including
///   `tmp/aerodj-tts-*.caf` written directly in tmp by builds up to 5dbf6d9;
/// - on iOS the directory uses `.completeUntilFirstUserAuthentication`: renders run while
///   music plays with the screen locked, and the file is written then read back after closing,
///   which `.complete` and `.completeUnlessOpen` would refuse while locked.
public struct SpeechTempFiles: Sendable {
    public static let prefix = "aerodj-tts-"
    public static let shared = SpeechTempFiles()

    public let directory: URL
    /// Where older builds wrote `aerodj-tts-*.caf` (tmp itself). Only prefix-matched `.caf` files are removed there.
    public let legacyDirectory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aerodj-speech", isDirectory: true),
                legacyDirectory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    /// A new, unique file URL in `directory` (created if needed).
    public func makeURL() throws -> URL {
        #if os(iOS)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: directory.path)
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #endif
        return directory.appendingPathComponent("\(Self.prefix)\(UUID().uuidString).caf", isDirectory: false)
    }

    /// Deletes everything in `directory`, plus legacy `aerodj-tts-*.caf` files in `legacyDirectory`. Returns how many entries were removed.
    @discardableResult
    public func sweep() -> Int {
        let fm = FileManager.default
        let legacy = ((try? fm.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(Self.prefix) && $0.pathExtension == "caf" }
        let entries = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []) + legacy
        return entries.reduce(0) { count, url in (try? FileManager.default.removeItem(at: url)) != nil ? count + 1 : count }
    }

    /// Runs `body` with a fresh temp file URL and always deletes the file afterwards.
    public func withFile<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = try makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }
}
