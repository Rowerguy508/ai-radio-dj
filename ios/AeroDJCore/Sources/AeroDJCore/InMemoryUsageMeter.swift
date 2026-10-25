import Foundation

/// In-memory usage meter for tests and local dev. Production uses a persisted store.
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
        // In-memory meter: all records are current-session; a persisted store
        // would filter by calendar day.
        return UsageSummary(
            userID: userID,
            generatedSeconds: generated,
            estimatedBillableUnits: units,
            callsToday: userRecords.count
        )
    }
}
