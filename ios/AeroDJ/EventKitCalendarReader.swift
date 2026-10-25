import AeroDJCore
import EventKit
import Foundation

/// Read-only EventKit bridge for `CalendarContextSource`. Requests full access
/// (iOS 17 API; the deployment target is 17.0, so no pre-17 fallback is needed)
/// only when the user adds the calendar source. Never requests write access.
final class EventKitCalendarReader: CalendarEventReading, @unchecked Sendable {
    // EKEventStore is thread-safe for reads but not marked Sendable.
    private let store = EKEventStore()

    func access() async -> CalendarAccess {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func calendars() async -> [CalendarDescriptor] {
        guard await access() == .fullAccess else { return [] }
        return store.calendars(for: .event).map { CalendarDescriptor(id: $0.calendarIdentifier, title: $0.title) }
    }

    func requestFullAccess() async throws -> CalendarAccess {
        let store = self.store
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
        return await access()
    }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEventSnapshot] {
        let calendars = calendarIDs.map { ids in store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } }
        if let calendars, calendars.isEmpty { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.snapshot)
    }

    static func map(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        // `.authorized` is the deprecated pre-17 value; treat it as full access.
        case .authorized: .fullAccess
        @unknown default: .denied
        }
    }

    static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot {
        let status: CalendarEventSnapshot.Status = switch event.status {
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .canceled
        default: .none
        }
        let availability: CalendarEventSnapshot.Availability = switch event.availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        default: .notSupported
        }
        return CalendarEventSnapshot(
            calendarItemID: event.calendarItemIdentifier,
            occurrenceDate: event.occurrenceDate ?? event.startDate,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            status: status,
            availability: availability,
            calendarID: event.calendar?.calendarIdentifier ?? ""
        )
    }
}
