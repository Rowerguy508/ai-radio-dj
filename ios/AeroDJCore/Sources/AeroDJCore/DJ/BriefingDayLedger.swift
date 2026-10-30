import Foundation

/// A local calendar day (year-month-day in a given time zone). Not a timestamp: two
/// instants on the same local date are the same day, whatever their hour.
public struct LocalDay: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    /// `yyyy-MM-dd`, the stored form.
    public init?(key: String) {
        let parts = key.split(separator: "-").map { Int($0) }
        guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2],
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { key }

    public static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// Where the last briefed local day is kept. On the device only; never synced or sent.
public protocol BriefingDayStore: Sendable {
    func lastBriefedDay() -> String?
    func setLastBriefedDay(_ key: String)
}

/// `UserDefaults` store. One key, holding a `yyyy-MM-dd` string and nothing else.
public final class UserDefaultsBriefingDayStore: BriefingDayStore, @unchecked Sendable {
    public static let defaultKey = "onairly.briefing.lastBriefedLocalDay"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsBriefingDayStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func lastBriefedDay() -> String? { defaults.string(forKey: key) }
    public func setLastBriefedDay(_ value: String) { defaults.set(value, forKey: key) }
}

public final class InMemoryBriefingDayStore: BriefingDayStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func lastBriefedDay() -> String? { lock.withLock { value } }
    public func setLastBriefedDay(_ value: String) { lock.withLock { self.value = value } }
}

/// The briefing plays once per local day: on the first listening session of the day, at
/// any hour (owner, Oct 29 2026). The clock and the time zone are injected and read on
/// every call, so a time-zone change is seen at once.
///
/// "Briefed today" means the stored day is today *or later*. Flying east past midnight
/// gives a later local day, so it briefs again. Going back west into a day that is already
/// briefed (the stored day is ahead of the new local day) does not brief a second time.
public final class BriefingDayLedger: @unchecked Sendable {
    private let store: any BriefingDayStore
    public let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone

    public init(store: any BriefingDayStore,
                now: @escaping @Sendable () -> Date = { Date() },
                timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }) {
        self.store = store
        self.now = now
        self.timeZone = timeZone
    }

    /// The app's ledger: `UserDefaults.standard`, the real clock, the current time zone.
    public static let standard = BriefingDayLedger(store: UserDefaultsBriefingDayStore())

    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() },
                                timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }) -> BriefingDayLedger {
        BriefingDayLedger(store: InMemoryBriefingDayStore(), now: now, timeZone: timeZone)
    }

    public var today: LocalDay { LocalDay(now(), timeZone: timeZone()) }

    /// A missing or unreadable value is "not briefed": the briefing itself is still gated
    /// by consent and sensitivity, so this only decides whether it may run again.
    public var hasBriefedToday: Bool {
        guard let raw = store.lastBriefedDay(), let last = LocalDay(key: raw) else { return false }
        return last >= today
    }

    /// Records today. Never moves the stored day backwards.
    public func markBriefedToday() {
        let day = today
        if let raw = store.lastBriefedDay(), let last = LocalDay(key: raw), last >= day { return }
        store.setLastBriefedDay(day.key)
    }
}
