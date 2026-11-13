import Foundation
#if canImport(os)
import os
#endif

// #318 (-Echo): the lines a listener just heard must not open the next session.
// `TemplatePool`'s used-set and `RecentSpokenTemplates` live inside one `DJScriptWriter`,
// and each session builds a new writer, so a fresh launch could air the same greeting
// and sign-off immediately.
//
// What is stored, and nothing else: template identifiers. A template id is the FNV-1a 64
// of the normalized template (`RecentSpokenTemplates.key`), 16 lowercase hex digits. The
// file never holds track titles, artists, track ids, station names, personal content, or
// spoken text. Only lines that actually aired are recorded (a replan's forgotten breaks
// are not). On-device only, excluded from backup the same way as the voice cache, and
// bounded. Unknown ids are ignored. A corrupt file starts fresh and never crashes.
//
// Schema (`DJLineMemory/recent-templates.json`), version 1:
//   { "v": 1,
//     "pools": { "<poolKey>": { "used": ["<id>", ...], "last": "<id>" } },
//     "recent": [ ["<id>", ...], ... ] }
// `pools` is the aired rotation of each phrase bank (oldest first). `last` is the latest
// aired id in that bank, so a full cycle still does not repeat it. `recent` is the aired
// breaks of the cross-pool window, oldest first, one inner array per break.
// Pool keys are a fixed vocabulary (`SpokenLinePool`): `backAnnounce`, `closing`,
// `artistFocus`, `stationID`, `continuation`, `briefingLead`, `briefingOutro`, `combined`,
// `catalogFact`, `opener.station`, `atmosphere.<dayPart>`, `greeting.<dayPart>`,
// `opener.setup.<dayPart>`, `timeCheck.<relation>`.

/// Stable id of one phrase-bank template. Not the template, and not anything it fills in.
enum SpokenTemplateID {
    /// FNV-1a 64 of the normalized template, as 16 lowercase hex digits.
    static func of(_ template: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in RecentSpokenTemplates.key(template).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

/// Fixed pool names. No listener data: the day part and the time-check relation are enums.
enum SpokenLinePool {
    static let backAnnounce = "backAnnounce"
    static let closing = "closing"
    static let artistFocus = "artistFocus"
    static let stationID = "stationID"
    static let continuation = "continuation"
    static let briefingLead = "briefingLead"
    static let briefingOutro = "briefingOutro"
    static let combined = "combined"
    static let catalogFact = "catalogFact"
    static let openerStation = "opener.station"
    static func atmosphere(_ part: DayPart) -> String { "atmosphere.\(part.rawValue)" }
    static func greeting(_ part: DayPart) -> String { "greeting.\(part.rawValue)" }
    static func openerSetup(_ part: DayPart) -> String { "opener.setup.\(part.rawValue)" }
    static func timeCheck(_ relation: DJTimeCheckRelation) -> String { "timeCheck.\(relation.rawValue)" }
}

/// The on-device recent-use set (#318). Template ids only.
public struct SpokenLineMemory: Equatable, Sendable, Codable {
    public static let formatVersion = 1
    /// The cross-pool window (`DJBreakShapeConfig` default `recentBreakWindow`).
    public static let maxRecentBreaks = 6
    /// A show opener joins a handful of templates into a few cues. Past this, extras are dropped.
    public static let maxIDsPerBreak = 8
    /// Larger than any phrase bank, so a full rotation fits and a hostile file cannot grow.
    public static let maxIDsPerPool = 64
    public static let maxPools = 48
    /// A file bigger than this is treated as corrupt and not decoded.
    public static let maxFileBytes = 64 * 1024

    /// Aired template ids in one pool since its last cycle, oldest first. `last` is the newest.
    public struct Pool: Equatable, Sendable, Codable {
        public var used: [String]
        public var last: String?
        public init(used: [String] = [], last: String? = nil) {
            self.used = used
            self.last = last
        }
    }

    public var pools: [String: Pool]
    public var recent: [[String]]

    public static let empty = SpokenLineMemory(pools: [:], recent: [])

    public init(pools: [String: Pool] = [:], recent: [[String]] = []) {
        self.pools = pools
        self.recent = recent
    }

    private enum CodingKeys: String, CodingKey { case v, pools, recent }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == Self.formatVersion else { throw SpokenLineMemoryError.unsupportedVersion }
        pools = try container.decodeIfPresent([String: Pool].self, forKey: .pools) ?? [:]
        recent = try container.decodeIfPresent([[String]].self, forKey: .recent) ?? []
        clamp()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .v)
        try container.encode(pools, forKey: .pools)
        try container.encode(recent, forKey: .recent)
    }

    /// Merges one aired break. Ids absent from `known` (a pool that changed, or garbage) are
    /// ignored. A pool whose aired set already covers every current template cycles, keeping
    /// only this break's ids, and `last` so the next draw does not repeat the newest.
    public mutating func record(pools aired: [String: [String]], recent breakIDs: [String],
                                known: [String: Set<String>]) {
        let knownIDs = Set(known.values.flatMap { $0 })
        for (key, ids) in aired {
            guard Self.allowedKey(key) else { continue }
            let knownPool = known[key] ?? []
            var entry = pools[key] ?? Pool()
            entry.used = Self.unique(entry.used.filter { knownPool.contains($0) })
            if let last = entry.last, !knownPool.contains(last) { entry.last = entry.used.last }
            let fresh = ids.compactMap(Self.cleanID).filter { knownPool.contains($0) }
            guard !fresh.isEmpty else {
                if entry.used.isEmpty, entry.last == nil { pools[key] = nil } else { pools[key] = entry }
                continue
            }
            if !knownPool.isEmpty, knownPool.isSubset(of: Set(entry.used)) { entry.used = [] }
            for id in fresh {
                if !entry.used.contains(id) { entry.used.append(id) }
                entry.last = id
            }
            if entry.used.count > Self.maxIDsPerPool {
                entry.used.removeFirst(entry.used.count - Self.maxIDsPerPool)
            }
            pools[key] = entry
        }
        let recentIDs = breakIDs.compactMap(Self.cleanID).filter { knownIDs.contains($0) }
        if !recentIDs.isEmpty {
            recent.append(Array(recentIDs.prefix(Self.maxIDsPerBreak)))
            if recent.count > Self.maxRecentBreaks { recent.removeFirst(recent.count - Self.maxRecentBreaks) }
        }
        clamp()
    }

    /// Drops ids and keys that are not the schema, and enforces the bounds. A decoded file
    /// with one bad id keeps the rest; a file that does not decode at all is never passed here.
    mutating func clamp() {
        var kept: [String: Pool] = [:]
        let keys = pools.keys.sorted()
        for key in keys {
            guard Self.allowedKey(key), let pool = pools[key] else { continue }
            var used: [String] = []
            for id in pool.used {
                guard let id = Self.cleanID(id), !used.contains(id) else { continue }
                used.append(id)
                if used.count == Self.maxIDsPerPool { break }
            }
            let last = pool.last.flatMap(Self.cleanID)
            if used.isEmpty, last == nil { continue }
            kept[key] = Pool(used: used, last: last)
            if kept.count == Self.maxPools { break }
        }
        pools = kept
        var breaks: [[String]] = []
        for line in recent.suffix(Self.maxRecentBreaks) {
            var ids: [String] = []
            for id in line {
                guard let id = Self.cleanID(id) else { continue }
                ids.append(id)
                if ids.count == Self.maxIDsPerBreak { break }
            }
            if !ids.isEmpty { breaks.append(ids) }
        }
        recent = breaks
    }

    static func cleanID(_ id: String) -> String? {
        let folded = id.lowercased()
        guard (8...32).contains(folded.count) else { return nil }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard folded.unicodeScalars.allSatisfy({ hex.contains($0) }) else { return nil }
        return folded
    }

    static func allowedKey(_ key: String) -> Bool {
        guard (1...48).contains(key.count) else { return false }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "."))
        return key.unicodeScalars.allSatisfy { ok.contains($0) }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var out: [String] = []
        for id in ids where !out.contains(id) { out.append(id) }
        return out
    }
}

enum SpokenLineMemoryError: Error {
    case unsupportedVersion
}

/// Where aired template ids live across sessions (#318).
public protocol SpokenLineMemoryStoring: Sendable {
    func load() -> SpokenLineMemory
    /// Merges one aired break. Never throws: a bad id is ignored, a failed write stays in memory.
    func record(pools: [String: [String]], recent: [String], known: [String: Set<String>])
    /// Consent withdrawal and data reset. Empties the set and deletes any file.
    func purge()
}

/// Process-lifetime store. The default for tests and for a session that was not given a file.
public final class InMemorySpokenLineMemoryStore: SpokenLineMemoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state = SpokenLineMemory.empty

    public init() {}

    public func load() -> SpokenLineMemory { lock.withLock { state } }

    public func record(pools: [String: [String]], recent: [String], known: [String: Set<String>]) {
        lock.withLock { state.record(pools: pools, recent: recent, known: known) }
    }

    public func purge() { lock.withLock { state = .empty } }
}

/// Content-free log when the folder cannot be excluded from backup. No path, no ids.
public enum SpokenLineMemoryLog {
    public enum Moment: String, Sendable { case create, open }

    public static func message(_ moment: Moment) -> String {
        "AeroDJ.djLineMemory backup exclusion failed moment=\(moment.rawValue)"
    }

    public static let emit: @Sendable (String) -> Void = { line in
        #if canImport(os)
        Logger(subsystem: "com.aerodj.app", category: "djLineMemory").error("\(line, privacy: .public)")
        #endif
    }
}

/// `Application Support/DJLineMemory/recent-templates.json`. Excluded from iCloud and computer
/// backup, like `Voice/Cache`. A newer `v` is left on disk and this process starts fresh
/// without overwriting it. Anything else unreadable starts fresh and may be replaced.
public final class FileSpokenLineMemoryStore: SpokenLineMemoryStoring, @unchecked Sendable {
    public let fileURL: URL
    private let backupExclusion: any BackupExclusionMarking
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var state = SpokenLineMemory.empty
    /// False when the folder could not be marked excluded: nothing more is written this session.
    private var diskOpen = true
    /// False when the file is a newer version: this build must not replace it.
    private var allowOverwrite = true

    public static let writingOptions: Data.WritingOptions = {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return options
    }()

    /// `DJLineMemory/recent-templates.json` under `applicationSupport`.
    public static func defaultURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("DJLineMemory", isDirectory: true)
            .appendingPathComponent("recent-templates.json")
    }

    public init(fileURL: URL, backupExclusion: any BackupExclusionMarking = FoundationBackupExclusion(),
                log: @escaping @Sendable (String) -> Void = SpokenLineMemoryLog.emit) {
        self.fileURL = fileURL
        self.backupExclusion = backupExclusion
        self.log = log
        let folder = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) {
            diskOpen = markExcluded(folder, .open)
                && (FileManager.default.fileExists(atPath: fileURL.path) ? markExcluded(fileURL, .open) : true)
        }
        let loaded = Self.read(fileURL)
        state = loaded.memory
        allowOverwrite = loaded.allowOverwrite
    }

    public func load() -> SpokenLineMemory { lock.withLock { state } }

    public func record(pools: [String: [String]], recent: [String], known: [String: Set<String>]) {
        lock.withLock {
            state.record(pools: pools, recent: recent, known: known)
            persistLocked()
        }
    }

    public func purge() {
        lock.withLock {
            state = .empty
            allowOverwrite = true
            diskOpen = true
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func persistLocked() {
        guard diskOpen, allowOverwrite else { return }
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            diskOpen = false
            return
        }
        guard markExcluded(folder, .create) else { diskOpen = false; return }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(state)
        } catch { return }
        do { try data.write(to: fileURL, options: Self.writingOptions) } catch { return }
        if !markExcluded(fileURL, .create) { diskOpen = false }
    }

    /// A failed mark or a read-back that says the folder is not excluded. A nil read-back
    /// (Linux, no such attribute) counts as excluded, matching `FileAudioCache`.
    private func markExcluded(_ url: URL, _ moment: SpokenLineMemoryLog.Moment) -> Bool {
        do { try backupExclusion.markExcluded(url) } catch {
            log(SpokenLineMemoryLog.message(moment))
            return false
        }
        let excluded: Bool?
        do { excluded = try backupExclusion.isExcluded(url) } catch { excluded = false }
        if excluded == false {
            log(SpokenLineMemoryLog.message(moment))
            return false
        }
        return true
    }

    private struct Header: Decodable { let v: Int }

    /// `allowOverwrite` is false only for a newer version, which is left untouched.
    private static func read(_ url: URL) -> (memory: SpokenLineMemory, allowOverwrite: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.empty, true) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return (.empty, true) }
        guard data.count <= SpokenLineMemory.maxFileBytes else { return (.empty, true) }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return (.empty, true) }
        guard header.v == SpokenLineMemory.formatVersion else {
            return (.empty, header.v < SpokenLineMemory.formatVersion)
        }
        guard let memory = try? JSONDecoder().decode(SpokenLineMemory.self, from: data) else { return (.empty, true) }
        return (memory, true)
    }
}
