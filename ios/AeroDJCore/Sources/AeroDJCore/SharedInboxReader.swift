import Foundation

/// Why an inbox file was purged instead of loaded.
public enum SharedInboxPurgeReason: Error, Equatable, Sendable {
    case expired
    case malformed      // not valid JSON for `SharedInboxItem`, or wrong file name
    case invalid        // decoded, but violates the envelope's own limits
    case tooLarge
    case forwardDated   // createdAt is in the future (wrong device clock); would dodge retention
}

public struct SharedInboxLoadResult: Equatable, Sendable {
    /// Valid, unexpired items, oldest first.
    public let items: [SharedInboxItem]
    /// File names removed during this load, with the reason.
    public let purged: [String: SharedInboxPurgeReason]
}

/// Host-side reader for the App Group inbox the Share Extension writes
/// (`<container>/Inbox/<uuid>.json`). Reads only that directory, re-validates
/// every envelope (the file is untrusted input), and deletes expired or
/// invalid files so retention is enforced on every load.
public struct SharedInboxReader: Sendable {
    public let directory: URL
    /// Generous bound on the JSON envelope; content itself is capped separately.
    public static let maxFileBytes = SharedInboxItem.maxContentBytes * 2 + 4096
    /// Tolerated clock skew between extension and host.
    public static let maxClockSkew: TimeInterval = 5 * 60

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(now: Date) throws -> SharedInboxLoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            return SharedInboxLoadResult(items: [], purged: [:])
        }
        var items: [SharedInboxItem] = []
        var purged: [String: SharedInboxPurgeReason] = [:]

        for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
            if name.hasPrefix(".") { continue } // e.g. atomic-write temp files
            let file = directory.appendingPathComponent(name, isDirectory: false)
            // Never purge (recursively delete) anything that isn't a regular file.
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let result = Self.validate(name: name, file: file, now: now)
            switch result {
            case .success(let item):
                items.append(item)
            case .failure(let reason):
                try? fm.removeItem(at: file)
                purged[name] = reason
            }
        }
        items.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return SharedInboxLoadResult(items: items, purged: purged)
    }

    /// Deletes one item's file. Deleting an already-missing item succeeds.
    public func delete(id: UUID) throws {
        let file = directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// Atomically rewrites an existing envelope (e.g. after redaction) with the
    /// same file protection the Share Extension uses.
    public func rewrite(_ item: SharedInboxItem) throws {
        let file = directory.appendingPathComponent("\(item.id.uuidString).json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else { throw SharedReviewError.unknownItem }
        try ProtectedFile.write(JSONEncoder().encode(item), to: file)
    }

    static func validate(name: String, file: URL, now: Date) -> Result<SharedInboxItem, SharedInboxPurgeReason> {
        guard name.hasSuffix(".json"), let fileID = UUID(uuidString: String(name.dropLast(5))) else {
            return .failure(.malformed)
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size <= maxFileBytes else { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: file),
              let item = try? JSONDecoder().decode(SharedInboxItem.self, from: data) else {
            return .failure(.malformed)
        }
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.id == fileID, item.source == .userShared, !trimmed.isEmpty,
              item.content.utf8.count <= SharedInboxItem.maxContentBytes,
              item.expiresAt > item.createdAt,
              item.expiresAt.timeIntervalSince(item.createdAt) <= SharedInboxItem.defaultRetention
        else { return .failure(.invalid) }
        if item.createdAt > now.addingTimeInterval(maxClockSkew) { return .failure(.forwardDated) }
        if item.isExpired(at: now) { return .failure(.expired) }
        return .success(item)
    }
}

/// Atomic writes with iOS Data Protection (`completeUntilFirstUserAuthentication`,
/// matching the Share Extension). Other platforms: atomic only.
enum ProtectedFile {
    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}
