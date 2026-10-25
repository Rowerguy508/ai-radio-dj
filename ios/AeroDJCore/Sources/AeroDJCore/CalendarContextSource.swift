import Foundation

/// Calendar permission as the app sees it. Mirrors EventKit's iOS 17 states;
/// only `.fullAccess` can read events.
public enum CalendarAccess: String, Sendable {
    case notDetermined, restricted, denied, writeOnly, fullAccess
}

public enum CalendarContextError: Error, Equatable, Sendable {
    /// Access isn't `.fullAccess`; the UI shows a distinct state per case.
    case accessUnavailable(CalendarAccess)
}

/// One event occurrence, bridged from EventKit by the app target so this
/// module stays EventKit-free and testable on Linux.
public struct CalendarEventSnapshot: Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case none, confirmed, tentative, canceled }
    public enum Availability: String, Codable, Sendable { case notSupported, busy, free, tentative, unavailable }

    /// `EKCalendarItem.calendarItemIdentifier`, shared by all occurrences of a series.
    public let calendarItemID: String
    /// `EKEvent.occurrenceDate` (falls back to `startDate` when nil).
    public let occurrenceDate: Date
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let status: Status
    public let availability: Availability
    /// `EKCalendar.calendarIdentifier`.
    public let calendarID: String

    public init(calendarItemID: String, occurrenceDate: Date, title: String, start: Date, end: Date,
                isAllDay: Bool, status: Status = .none, availability: Availability = .busy, calendarID: String) {
        self.calendarItemID = calendarItemID
        self.occurrenceDate = occurrenceDate
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.status = status
        self.availability = availability
        self.calendarID = calendarID
    }
}

/// A calendar the user can opt in, for the per-calendar picker.
public struct CalendarDescriptor: Equatable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Boundary to EventKit. Read-only: there is no write method.
public protocol CalendarEventReading: Sendable {
    func access() async -> CalendarAccess
    /// Readable event calendars, for opt-in. Empty without full access.
    func calendars() async -> [CalendarDescriptor]
    func requestFullAccess() async throws -> CalendarAccess
    /// Occurrences overlapping `[start, end)` in the given calendars (`nil` = all readable).
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEventSnapshot]
}

/// How events judged private are handled.
public enum PrivateEventHandling: String, Codable, Sendable {
    /// Narrated only as "Private event" with its time; sensitivity `.high`.
    case redact
    /// Dropped entirely.
    case exclude
}

/// User choices for the calendar source. Defaults are closed: no calendar is
/// read until the user opts it in, and nothing is narratable until consent.
public struct CalendarSourcePolicy: Equatable, Sendable {
    /// Calendars the user opted in (`EKCalendar.calendarIdentifier`). Empty = none.
    public var includedCalendarIDs: Set<String>
    /// Calendars whose events are always private.
    public var privateCalendarIDs: Set<String>
    /// Availabilities treated as private (EventKit exposes no per-event private
    /// flag; `.unavailable` is the closest signal). Add `.busy` to hide busy blocks.
    public var privateAvailabilities: Set<CalendarEventSnapshot.Availability>
    public var privateHandling: PrivateEventHandling
    /// Set to `.granted` once the user has opted calendar into briefings.
    public var consent: ConsentState
    public var maxTitleCharacters: Int

    public init(includedCalendarIDs: Set<String> = [], privateCalendarIDs: Set<String> = [],
                privateAvailabilities: Set<CalendarEventSnapshot.Availability> = [.unavailable],
                privateHandling: PrivateEventHandling = .redact, consent: ConsentState = .notRequested,
                maxTitleCharacters: Int = 80) {
        self.includedCalendarIDs = includedCalendarIDs
        self.privateCalendarIDs = privateCalendarIDs
        self.privateAvailabilities = privateAvailabilities
        self.privateHandling = privateHandling
        self.consent = consent
        self.maxTitleCharacters = maxTitleCharacters
    }

    func isPrivate(_ event: CalendarEventSnapshot) -> Bool {
        privateCalendarIDs.contains(event.calendarID) || privateAvailabilities.contains(event.availability)
    }
}

/// Today's calendar occurrences as `ContextItem`s. Clock and calendar
/// (time zone) are injected; nothing reads the system clock.
public struct CalendarContextSource: ContextSource {
    public let source: ContextSourceKind = .calendar
    public let reader: any CalendarEventReading
    public let policy: CalendarSourcePolicy
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(reader: any CalendarEventReading, policy: CalendarSourcePolicy = .init(),
                calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.policy = policy
        self.calendar = calendar
        self.now = now
    }

    public func fetchItems() async throws -> [ContextItem] {
        let access = await reader.access()
        guard access == .fullAccess else { throw CalendarContextError.accessUnavailable(access) }
        guard !policy.includedCalendarIDs.isEmpty else { return [] }  // opt-in per calendar
        let current = now()
        let dayStart = calendar.startOfDay(for: current)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let events = try await reader.events(from: dayStart, to: dayEnd, calendarIDs: policy.includedCalendarIDs)

        var seen: Set<String> = []
        return events
            .filter { $0.status != .canceled && $0.start < dayEnd && $0.end > dayStart }
            .filter { policy.includedCalendarIDs.contains($0.calendarID) }
            .filter { !(policy.privateHandling == .exclude && policy.isPrivate($0)) }
            .sorted { ($0.start, $0.calendarItemID) < ($1.start, $1.calendarItemID) }
            .filter { seen.insert(Self.provenance(for: $0)).inserted }
            .map { item(for: $0, dayStart: dayStart, dayEnd: dayEnd, capturedAt: current) }
    }

    func item(for event: CalendarEventSnapshot, dayStart: Date, dayEnd: Date, capturedAt: Date) -> ContextItem {
        let isPrivate = policy.isPrivate(event)
        let startedEarlier = event.start < dayStart
        let spansDay = event.isAllDay || (startedEarlier && event.end >= dayEnd)
        var parts: [String] = []
        if spansDay {
            parts.append("All day")
        } else {
            parts.append(startedEarlier ? "Until \(time(event.end))"
                         : event.end > event.start ? "\(time(event.start)) to \(time(event.end))" : time(event.start))
        }
        if event.end > dayEnd, let last = calendar.date(byAdding: .second, value: -1, to: event.end) {
            parts.append("through \(day(last))")
        }
        if event.status == .tentative { parts.append("tentative") }

        let provenance = Self.provenance(for: event)
        return ContextItem(
            id: Self.stableID(for: provenance),
            source: .calendar,
            createdAt: capturedAt,
            // All-day (or covering all of today) has no clock time: `eventAt` is nil,
            // so consumers never read midnight as a meeting time. Timed events keep
            // their real start; `expiresAt` (= end) marks ones still in progress.
            eventAt: spansDay ? nil : event.start,
            title: isPrivate ? "Private event" : title(event.title),
            summary: parts.joined(separator: ", "),
            sensitivity: isPrivate ? .high : .low,
            consent: policy.consent,
            expiresAt: event.end,
            provenance: provenance
        )
    }

    private func title(_ raw: String) -> String {
        let clean = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if clean.isEmpty { return "Untitled event" }
        return clean.count > policy.maxTitleCharacters ? String(clean.prefix(policy.maxTitleCharacters)) + "…" : clean
    }

    private func time(_ date: Date) -> String { format(date, calendar.component(.minute, from: date) == 0 ? "h a" : "h:mm a") }
    private func day(_ date: Date) -> String { format(date, "EEEE, MMM d") }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// `calendar-event:<series id>@<occurrence, ISO 8601 UTC>`; ids are opaque, never parsed.
    static func provenance(for event: CalendarEventSnapshot) -> String {
        let id = event.calendarItemID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? event.calendarItemID
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "calendar-event:\(id)@\(formatter.string(from: event.occurrenceDate))"
    }

    /// Deterministic UUID (FNV-1a 64 ×2, version 8 layout) so review state and
    /// dedupe survive refreshes. Not a secret; collisions are merely unlikely.
    static func stableID(for provenance: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            provenance.utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
        }
        var bytes = withUnsafeBytes(of: fnv(0xCBF2_9CE4_8422_2325).bigEndian, Array.init)
            + withUnsafeBytes(of: fnv(0x84222325CBF29CE4).bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
