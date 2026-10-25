import Foundation

/// Normalizes calendar events into `ContextItem`s. Pure logic, no EventKit —
/// testable with fixtures. Handles recurring dedupe, all-day, canceled,
/// timezone, and redaction.
public struct CalendarEvent: Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let isCanceled: Bool
    public let isPrivate: Bool
    public let calendarName: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool,
                isCanceled: Bool, isPrivate: Bool, calendarName: String?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCanceled = isCanceled
        self.isPrivate = isPrivate
        self.calendarName = calendarName
    }
}

/// Adapts raw `CalendarEvent`s into concise, privacy-aware `ContextItem`s.
public struct CalendarContextAdapter: Sendable {
    private let calendar: Calendar
    private let maxTitleLength: Int

    public init(calendar: Calendar = .current, maxTitleLength: Int = 60) {
        self.calendar = calendar
        self.maxTitleLength = maxTitleLength
    }

    /// Filter + map events occurring today into narratable items.
    public func todayItems(from events: [CalendarEvent], now: Date = Date(),
                           timezone: TimeZone = .current) -> [ContextItem] {
        var seenIDs: Set<String> = []
        var results: [ContextItem] = []

        for event in events.sorted(by: { $0.start < $1.start }) {
            // Skip canceled and private (unknown) events.
            guard !event.isCanceled, !event.isPrivate else { continue }
            // Dedupe recurring instances by stable id prefix.
            let dedupeKey = event.id.split(separator: "_").first.map(String.init) ?? event.id
            guard seenIDs.insert(dedupeKey).inserted else { continue }
            // Only today's events (all-day events count for their day).
            guard isToday(event, now: now, timezone: timezone) else { continue }

            results.append(
                ContextItem(
                    source: .calendar,
                    eventAt: event.start,
                    title: trimmed(event.title),
                    summary: calendarSummary(event),
                    sensitivity: .low,
                    consent: .notRequested,
                    provenance: "calendar://\(event.id)"
                )
            )
        }
        return results
    }

    private func trimmed(_ title: String) -> String {
        title.count > maxTitleLength ? String(title.prefix(maxTitleLength)) + "…" : title
    }

    /// One concise line; never full notes/location detail.
    private func calendarSummary(_ event: CalendarEvent) -> String {
        var parts: [String] = []
        if event.isAllDay {
            parts.append("All day")
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            fmt.timeZone = .current
            parts.append("\(fmt.string(from: event.start))")
        }
        parts.append(event.title)
        if let calendarName = event.calendarName {
            parts.append("(\(calendarName))")
        }
        return parts.joined(separator: " ")
    }

    private func isToday(_ event: CalendarEvent, now: Date, timezone: TimeZone) -> Bool {
        var cal = calendar
        cal.timeZone = timezone
        return cal.isDateInToday(event.start)
    }
}