import Foundation

/// Calendar-hour entry points for the Duo day-wash `TimelineView`.
///
/// Pure and UI-free so Linux can pin mid-hour, DST, and day-part behaviour.
/// Uses `dateInterval(of: .hour)` so a start that is not on the hour still lands
/// on the next civil hour, including when DST skips or repeats one. A fixed
/// 3600-second period can land up to 59 minutes late and drifts across DST.
public enum DayWashSchedule {
    /// The start of the hour that contains `date`.
    public static func currentHourStart(containing date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    /// The start of the next civil hour after `date`.
    ///
    /// If `date` is already an hour start, this is the following hour, not `date`
    /// itself. Across a spring-forward gap the next start is the first hour that
    /// exists (01:00 then 03:00 in America/New_York). Across a fall-back overlap
    /// both 01:00 instants are distinct hour starts.
    public static func nextHourStart(after date: Date, calendar: Calendar) -> Date {
        if let end = calendar.dateInterval(of: .hour, for: date)?.end {
            return end
        }
        return calendar.date(byAdding: .hour, value: 1, to: date)
            ?? date.addingTimeInterval(3600)
    }

    /// The start of the hour containing `date`, then each following hour start.
    public static func hourStarts(from date: Date, calendar: Calendar) -> UnfoldFirstSequence<Date> {
        sequence(first: currentHourStart(containing: date, calendar: calendar)) { previous in
            nextHourStart(after: previous, calendar: calendar)
        }
    }
}
