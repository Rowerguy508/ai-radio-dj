import Foundation

/// In-memory usage meter for tests and local dev. Records usage only; it does
/// not enforce any budget (enforcement is tracked in #22).
public actor InMemoryUsageMeter: UsageMeter {
    private var records: [String: [UsageRecord]] = [:]

    public init() {}

    public func record(_ usage: UsageRecord) async throws {
        records[usage.userID, default: []].append(usage)
    }

    public func currentUsage(for userID: String) async throws -> UsageSummary {
        let userRecords = records[userID] ?? []
        let generated = userRecords.reduce(0.0) { $0 + $1.generatedSeconds }
        let units = userRecords.reduce(0) { $0 + $1.estimatedBillableUnits }
        // Totals cover every record this meter holds; a persisted store would
        // also window by calendar day.
        return UsageSummary(
            userID: userID,
            generatedSeconds: generated,
            estimatedBillableUnits: units,
            callCount: userRecords.count
        )
    }
}
