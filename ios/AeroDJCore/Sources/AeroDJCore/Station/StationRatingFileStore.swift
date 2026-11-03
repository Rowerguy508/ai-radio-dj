import Foundation

/// Why the on-device ratings file could not be used. Never carries a song, station or path.
public enum StationRatingStoreError: Error, Equatable, Sendable {
    /// Written by a newer app (`version` above `StationRatingBook.formatVersion`). The file is left
    /// alone: this build never overwrites it (`StationRatingsModel` goes read-only).
    case newerVersion
    /// The file exists but could not be read (I/O, or before first unlock).
    case unreadable
    /// The file was read but is not a ratings book.
    case corrupt
    case writeFailed
    case deleteFailed
}

/// Song ratings on this device only (-Nova, PR B): `Application Support/Ratings/ratings.json`.
/// Sentinel's file rules (ratings scope §5), the same pattern as `FileStationConfigurationStore`
/// and `PhononModelStore`:
/// - written atomically, with `completeFileProtectionUntilFirstUserAuthentication` on iOS;
/// - `isExcludedFromBackup` on the `Ratings` folder and the file (no iCloud or iTunes backup, no sync);
/// - loaded with `StationRatingBook.todayKey` set, so an over-full station is trimmed for today.
/// Never logs anything.
public actor FileStationRatingStore: StationRatingStore {
    public let fileURL: URL
    private let today: @Sendable () -> Int

    /// What every save applies (pinned by tests on Linux, where file protection does not exist).
    public static let writingOptions: Data.WritingOptions = {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return options
    }()
    /// Sentinel: excluded from backup by default.
    public static let excludedFromBackup = true

    /// `Ratings/ratings.json` under `applicationSupport`.
    public static func defaultURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Ratings", isDirectory: true).appendingPathComponent("ratings.json")
    }

    public init(fileURL: URL, today: @escaping @Sendable () -> Int = { StationRatingsModel.dayNumber() }) {
        self.fileURL = fileURL
        self.today = today
    }

    public func load() async throws -> StationRatingBook {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return StationRatingBook() }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw StationRatingStoreError.unreadable }
        return try Self.decode(data, today: today())
    }

    /// Checks the version before the body, so a newer file is never mistaken for a corrupt one.
    static func decode(_ data: Data, today: Int) throws -> StationRatingBook {
        struct Header: Decodable { let version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw StationRatingStoreError.corrupt
        }
        guard header.version <= StationRatingBook.formatVersion else { throw StationRatingStoreError.newerVersion }
        let decoder = JSONDecoder()
        decoder.userInfo[StationRatingBook.todayKey] = today
        do { return try decoder.decode(StationRatingBook.self, from: data) } catch {
            throw StationRatingStoreError.corrupt
        }
    }

    static func encode(_ book: StationRatingBook) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(book)
    }

    public func save(_ book: StationRatingBook) async throws {
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.encode(book).write(to: fileURL, options: Self.writingOptions)
        } catch {
            throw StationRatingStoreError.writeFailed
        }
        Self.excludeFromBackup(folder)
        Self.excludeFromBackup(fileURL)
    }

    /// Settings "Clear all ratings", the purge-all listener, a data reset. A missing file is fine.
    public func deleteAll() async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { try FileManager.default.removeItem(at: fileURL) } catch { throw StationRatingStoreError.deleteFailed }
    }

    /// Best effort, like `PhononModelStore`: an atomic write replaces the file, so the file is marked
    /// again after every save. Darwin only (swift-corelibs-foundation has no backup attribute).
    private static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        guard excludedFromBackup else { return }
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }
}
