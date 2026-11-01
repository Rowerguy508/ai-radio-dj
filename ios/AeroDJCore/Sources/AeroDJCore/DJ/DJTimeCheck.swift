import Foundation

// Spoken time checks (lane 2 part 2, #342, -Fry). The one place a DJ line says a time. The time
// always comes from the clock the caller injects (`DJPlanClock.now`, the session's `now()`), read
// once when the break is planned. Nothing here reads the system clock.
//
// Rendering, all tested in `DJTimeCheckTests`:
//   - Rounded to the nearest 5 minutes (x:58 is the next hour, 11:58 is noon, 23:58 is midnight).
//   - The phrasing says which way it rounded: "It's 7:40." on the mark, "Coming up on 8 o'clock."
//     just before, "Just after 7:45." just after. Never "minutes past" a rounded hour.
//   - 12-hour locales: no am/pm (a live clock read is never ambiguous to the listener); the hour
//     mark is "8 o'clock", 12:00 is "noon" and 0:00 is "midnight".
//   - 24-hour locales: "19:40", "20:00"; noon and midnight are still spoken as words.

/// Which hour cycle the listener's locale reads the clock in.
public enum DJClockStyle: String, Sendable, CaseIterable {
    case twelveHour, twentyFourHour

    /// From the locale's preferred hour pattern ("j"): `H`/`k` mean 24-hour, anything else 12.
    public init(locale: Locale) {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h"
        self = pattern.contains("H") || pattern.contains("k") ? .twentyFourHour : .twelveHour
    }
}

/// The planning clock for one `DJScriptWriter.plan` call. Injected; Core never calls `Date()`.
public struct DJPlanClock: Sendable {
    /// The moment the break is planned (the session's `now()`). The spoken time comes from here.
    public var now: Date
    /// The listener's calendar and time zone.
    public var calendar: Calendar
    public var style: DJClockStyle
    /// Known air times by boundary (`afterTrack` in the plan's own track indices). A boundary
    /// missing here has an unknown air time.
    public var airTimes: [Int: Date]

    public init(now: Date, calendar: Calendar, style: DJClockStyle, airTimes: [Int: Date] = [:]) {
        self.now = now
        self.calendar = calendar
        self.style = style
        self.airTimes = airTimes
    }
}

/// Which way the spoken time was rounded from the real one.
public enum DJTimeCheckRelation: String, Sendable, CaseIterable {
    /// The clock reads the rounded time exactly.
    case on
    /// The real time is a minute or two before the rounded time.
    case comingUp
    /// The real time is a minute or two after the rounded time.
    case justAfter
}

/// Time-check phrasings. `{time}` is "7:40", "8 o'clock", "noon", "midnight" or "19:40".
/// One sentence, seven words or fewer, no day-part claims. Copy is Echo's to restyle (and to move
/// into `EditorialTone` later); the rules in `DJTimeCheck` do not depend on the wording.
public struct DJTimeCheckPhrases: Equatable, Sendable {
    public var on: [String]
    public var comingUp: [String]
    public var justAfter: [String]

    public init(on: [String] = DJTimeCheckPhrases.defaultOn, comingUp: [String] = DJTimeCheckPhrases.defaultComingUp,
                justAfter: [String] = DJTimeCheckPhrases.defaultJustAfter) {
        self.on = on
        self.comingUp = comingUp
        self.justAfter = justAfter
    }

    public func templates(for relation: DJTimeCheckRelation) -> [String] {
        switch relation {
        case .on: return on
        case .comingUp: return comingUp
        case .justAfter: return justAfter
        }
    }

    public static let defaultOn = ["It's {time}.", "Time check, it's {time}.", "Right now, it's {time}."]
    public static let defaultComingUp = ["Coming up on {time}.", "Almost {time}.", "Nearly {time} now."]
    public static let defaultJustAfter = ["Just after {time}.", "Just past {time}.", "A little after {time}."]
}

public enum DJTimeCheck {
    /// Minutes the spoken time is rounded to.
    public static let roundingMinutes = 5

    /// Rounds a wall-clock reading to the nearest `roundingMinutes`. Seconds are ignored (7:57:59
    /// reads 7:57). Wraps at midnight: 23:58 is 0:00.
    public static func rounded(hour: Int, minute: Int) -> (hour: Int, minute: Int, relation: DJTimeCheckRelation) {
        let raw = hour * 60 + minute
        let step = roundingMinutes
        let nearest = ((raw + step / 2) / step) * step
        let relation: DJTimeCheckRelation = nearest == raw ? .on : (nearest > raw ? .comingUp : .justAfter)
        let wrapped = nearest % (24 * 60)
        return (wrapped / 60, wrapped % 60, relation)
    }

    /// The `{time}` text for a rounded time.
    public static func spokenTime(hour: Int, minute: Int, style: DJClockStyle) -> String {
        if minute == 0 && hour == 0 { return "midnight" }
        if minute == 0 && hour == 12 { return "noon" }
        let mm = minute < 10 ? "0\(minute)" : "\(minute)"
        switch style {
        case .twelveHour:
            let h12 = hour % 12 == 0 ? 12 : hour % 12
            return minute == 0 ? "\(h12) o'clock" : "\(h12):\(mm)"
        case .twentyFourHour:
            let hh = hour == 0 ? "00" : "\(hour)"
            return "\(hh):\(mm)"
        }
    }

    /// The rounded `{time}` text and its relation for `date` in `calendar`'s time zone.
    public static func reading(_ date: Date, calendar: Calendar, style: DJClockStyle) -> (time: String, relation: DJTimeCheckRelation) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let r = rounded(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        return (spokenTime(hour: r.hour, minute: r.minute, style: style), r.relation)
    }

    /// Strips a planned time check whose break will air too far from when it was planned (the
    /// spoken time would be wrong). The rest of the break is kept: the time check is an optional
    /// line ahead of the closing line, so the closing line and its talk-over stay as they are.
    /// Unchanged when the break has no time check or the drift is within `maxDriftSeconds`.
    /// Nil when the time check was the only line (the boundary goes music-only).
    public static func droppingStale(_ djBreak: DJBreak, airTime: Date, maxDriftSeconds: Double) -> DJBreak? {
        guard let id = djBreak.timeCheckCueID, let plannedAt = djBreak.timeCheckPlannedAt,
              abs(airTime.timeIntervalSince(plannedAt)) > maxDriftSeconds else { return djBreak }
        guard djBreak.cues.contains(where: { $0.id != id }) else { return nil }
        var trimmed = DJBreak(afterTrack: djBreak.afterTrack, cues: djBreak.cues.filter { $0.id != id },
                              attributions: djBreak.attributions.filter { $0.key != id })
        trimmed.talkOverCueID = djBreak.talkOverCueID
        trimmed.shape = djBreak.shape
        return trimmed
    }
}
