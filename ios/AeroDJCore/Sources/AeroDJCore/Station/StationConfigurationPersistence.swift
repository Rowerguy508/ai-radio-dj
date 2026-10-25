import Foundation

/// Versioned on-disk form. Bump `currentVersion` only with a migration in `decodeMigrating`.
public struct StationConfigurationSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let state: StationConfigurationState

    public init(state: StationConfigurationState) {
        self.version = Self.currentVersion
        self.state = state
    }

    private enum CodingKeys: String, CodingKey { case version, active, pending }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A payload without a version predates versioning and is read as v1.
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else {
            throw StationConfigurationStoreError.newerVersion(version)
        }
        let active = try c.decodeIfPresent(StationConfiguration.self, forKey: .active) ?? .default
        let pending = try c.decodeIfPresent(StationConfiguration.self, forKey: .pending)
        self.version = Self.currentVersion
        self.state = StationConfigurationState(active: active, pending: pending)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(state.active, forKey: .active)
        try c.encodeIfPresent(state.pending, forKey: .pending)
    }

    public static func decode(_ data: Data) throws -> StationConfigurationSnapshot {
        do {
            return try JSONDecoder().decode(StationConfigurationSnapshot.self, from: data)
        } catch let error as StationConfigurationStoreError {
            throw error
        } catch {
            throw StationConfigurationStoreError.unreadable
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum StationConfigurationStoreError: Error, Equatable, Sendable {
    /// Saved by a newer app version. Read-only: do not overwrite it.
    case newerVersion(Int)
    /// Corrupt or not a configuration file.
    case unreadable
    case writeFailed
}

/// Local persistence boundary. `load()` returns `nil` when nothing was ever saved.
public protocol StationConfigurationPersisting: Sendable {
    func load() async throws -> StationConfigurationSnapshot?
    func save(_ snapshot: StationConfigurationSnapshot) async throws
}

/// For tests and SwiftUI previews.
public actor InMemoryStationConfigurationStore: StationConfigurationPersisting {
    public private(set) var data: Data?
    public private(set) var saveCount = 0
    public var failSaves = false

    public init(snapshot: StationConfigurationSnapshot? = nil) {
        self.data = try? snapshot?.encoded()
    }

    public init(rawData: Data?) { self.data = rawData }

    public func setFailSaves(_ fail: Bool) { failSaves = fail }

    public func load() async throws -> StationConfigurationSnapshot? {
        guard let data else { return nil }
        return try StationConfigurationSnapshot.decode(data)
    }

    public func save(_ snapshot: StationConfigurationSnapshot) async throws {
        if failSaves { throw StationConfigurationStoreError.writeFailed }
        data = try snapshot.encoded()
        saveCount += 1
    }
}

/// JSON file in the app's container (pass an Application Support URL). Atomic writes.
/// Contains preferences only: no context items, no credentials.
public actor FileStationConfigurationStore: StationConfigurationPersisting {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() async throws -> StationConfigurationSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw StationConfigurationStoreError.unreadable }
        return try StationConfigurationSnapshot.decode(data)
    }

    public func save(_ snapshot: StationConfigurationSnapshot) async throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try snapshot.encoded().write(to: fileURL, options: options)
        } catch {
            throw StationConfigurationStoreError.writeFailed
        }
    }
}
