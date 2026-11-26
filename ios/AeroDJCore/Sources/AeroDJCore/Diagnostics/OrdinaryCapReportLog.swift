// #329 (2) (-Fry): one diagnostics line per boundary from `DJBreakSession.ordinaryCapReport`.
// Compiled only in Debug (so `swift test` runs its tests) and in AERODJ_P0_DIAG builds.
#if DEBUG || AERODJ_P0_DIAG
#if canImport(os)
import os
#endif

/// The cap report for one boundary, as integers and fixed reason codes only.
///
/// No cue text and no cue IDs: a report-only briefing cue reuses its connection item's id as its
/// cue id (`LiveQueueBriefing.reportOnlyCue`), so a cue ID is not always opaque. Every value here
/// is a boundary index, a count, a 0/1 flag or a `rawValue` of a closed reason enum.
public enum OrdinaryCapReportLog {
    /// The line for boundary `k`, or nil when the report has nothing for it.
    public static func message(_ report: OrdinaryBreakCapReport, afterTrack k: Int) -> String? {
        let trimmed = report.trimmedOptionalLines[k] ?? 0
        let overCap = report.skippedOverCap.contains(k)
        let drop = report.droppedTimeChecks[k]?.reason.rawValue
        let opener = report.omittedOpenerTimeChecks[k]?.rawValue
        guard trimmed > 0 || overCap || drop != nil || opener != nil else { return nil }
        return "AeroDJ.dj capReport after=\(k) trimmed=\(trimmed) overCap=\(overCap ? 1 : 0)"
            + " timeCheckDrop=\(drop ?? "none") openerTime=\(opener ?? "none")"
    }

    /// Logs boundary `k`'s line, if any. Returns the line (for tests).
    @discardableResult
    public static func record(_ report: OrdinaryBreakCapReport, afterTrack k: Int) -> String? {
        guard let line = message(report, afterTrack: k) else { return nil }
        #if canImport(os)
        // Logs exactly `line`, so the tests that pin message() pin what is logged. Public is safe
        // only because message() builds the line from integers and closed reason codes; keep it so.
        Logger(subsystem: "com.aerodj.app", category: "dj").notice("\(line, privacy: .public)")
        #endif
        return line
    }
}
#endif
