import Foundation

// #332 (-Echo): personal updates may air at any time of day, so the same approved item must
// not be announced on every queue start. The ledger counts airings per source item id for the
// current LOCAL calendar day (`Calendar` injected; default `.current`). A new day starts empty.
//
// It is told what actually aired (`recordAired`), not what was offered: an update handed to a
// queue that ends before its break keeps its chance for later that day. The ledger never
// decides consent; `LiveQueueBriefing` and `DJBreakSession` still check every row.
//
// Lifetime: the ledger lives as long as its owner. With `InMemoryPersonalUpdatePlayStore` it
// survives queue changes and station starts within one app run, not a relaunch. With
// `UserDefaultsPersonalUpdatePlayStore` it survives a relaunch. Only today's item ids and
// counts are stored (no titles or text), on device.

/// Airings for one local calendar day.
public struct PersonalUpdatePlays: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` in the ledger's calendar.
    public var day: String
    /// Airings per source item id on `day`.
    public var counts: [UUID: Int]

    public init(day: String, counts: [UUID: Int] = [:]) {
        self.day = day
        self.counts = counts
    }
}

/// Where the ledger keeps today's airings.
public protocol PersonalUpdatePlayStore: Sendable {
    func load() -> PersonalUpdatePlays?
    func save(_ plays: PersonalUpdatePlays)
}

/// Process-lifetime store (default). Lost on relaunch.
public final class InMemoryPersonalUpdatePlayStore: PersonalUpdatePlayStore, @unchecked Sendable {
    private let lock = NSLock()
    private var plays: PersonalUpdatePlays?

    public init() {}

    public func load() -> PersonalUpdatePlays? { lock.withLock { plays } }
    public func save(_ plays: PersonalUpdatePlays) { lock.withLock { self.plays = plays } }
}

/// On-device store in `UserDefaults` (already a declared required-reason API, CA92.1).
/// Keeps one day at a time, so it never grows past today's item ids.
public final class UserDefaultsPersonalUpdatePlayStore: PersonalUpdatePlayStore, @unchecked Sendable {
    public static let defaultKey = "aerodj.personalUpdatePlays.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsPersonalUpdatePlayStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PersonalUpdatePlays? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersonalUpdatePlays.self, from: data)
    }

    public func save(_ plays: PersonalUpdatePlays) {
        guard let data = try? JSONEncoder().encode(plays) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Once-a-day repeat limit for personal updates, keyed by source item id.
public final class PersonalUpdateLedger: @unchecked Sendable {
    /// Airings allowed per item per local day. #332 default: 1.
    public let playsPerDay: Int
    private let store: any PersonalUpdatePlayStore
    private let calendar: Calendar
    private let lock = NSLock()

    public init(store: any PersonalUpdatePlayStore = InMemoryPersonalUpdatePlayStore(),
                calendar: Calendar = .current,
                playsPerDay: Int = DJCadence.defaultPersonalUpdatePlaysPerDay) {
        self.store = store
        self.calendar = calendar
        self.playsPerDay = max(1, playsPerDay)
    }

    /// Local calendar day of `date`, as `yyyy-MM-dd`.
    public func dayKey(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// True when `itemID` has already aired `playsPerDay` times on `now`'s local day.
    public func hasReachedLimit(_ itemID: UUID, at now: Date) -> Bool {
        lock.withLock { (today(now).counts[itemID] ?? 0) >= playsPerDay }
    }

    /// Items at their limit on `now`'s local day.
    public func limitedItemIDs(at now: Date) -> Set<UUID> {
        lock.withLock { Set(today(now).counts.filter { $0.value >= playsPerDay }.keys) }
    }

    /// Counts each personal content cue (`sourceItemID != nil`) once. Call when the break that
    /// carries them is handed to the player (`DJBreakSession`, where `deliveredBriefing` is
    /// updated). Presenter and track lines are ignored.
    public func recordAired(_ cues: [NarrationCue], at now: Date) {
        let ids = Set(cues.compactMap(\.sourceItemID))
        guard !ids.isEmpty else { return }
        lock.withLock {
            var plays = today(now)
            for id in ids { plays.counts[id, default: 0] += 1 }
            store.save(plays)
        }
    }

    /// Today's airings; a stored earlier day reads as empty.
    private func today(_ now: Date) -> PersonalUpdatePlays {
        let day = dayKey(for: now)
        guard let stored = store.load(), stored.day == day else { return PersonalUpdatePlays(day: day) }
        return stored
    }
}
