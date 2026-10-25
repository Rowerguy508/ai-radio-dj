import Foundation
import EventKit
import AeroDJCore

/// EventKit bridge. Requests FULL calendar access only when the user opts in.
/// Reads today's events via CalendarContextAdapter (pure, tested). Never
/// requests calendar write permission — this is strictly read-only.
@MainActor
final class CalendarService: ObservableObject {
    enum AccessState: Equatable {
        case unknown
        case authorized
        case denied
        case restricted
        case notDetermined
    }

    @Published private(set) var accessState: AccessState = .unknown
    @Published private(set) var todayItems: [ContextItem] = []

    private let store = EKEventStore()
    private let adapter = CalendarContextAdapter()

    /// Request full-access read. Explicit denied/restricted states.
    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            accessState = granted ? .authorized : .denied
        } catch {
            accessState = .denied
        }
        if accessState == .authorized { await refresh() }
    }

    /// Read today's events through the testable adapter.
    func refresh() async {
        guard accessState == .authorized else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        todayItems = adapter.todayItems(from: events.map(CalendarEvent.init))
    }
}

extension CalendarEvent {
    /// Bridge an EventKit `EKEvent` into the pure domain type.
    init(_ event: EKEvent) {
        self.init(
            id: event.eventIdentifier,
            title: event.title,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled,
            isPrivate: false, // EKEvent exposes no reliable "private" flag — redaction is a future enhancement.
            calendarName: event.calendar?.title
        )
    }
}