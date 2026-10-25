import Foundation

/// Errors surfaced by `CostLimitedVoiceProvider`.
public enum VoiceError: Error, Equatable, Sendable {
    case dailyBudgetExceeded(limitSeconds: Double, usedSeconds: Double)
    case cacheCollision // a cross-user cache key was rejected
    case providerFailed(underlying: String)
}

/// Wraps a `VoiceProvider` with cost metering and a hard per-user daily cap.
/// Meters characters + audio duration; no speculative requests.
public struct CostLimitedVoiceProvider: VoiceProvider {
    private let inner: any VoiceProvider
    private let meter: any UsageMeter
    private let dailyCapSeconds: Double

    public init(inner: any VoiceProvider, meter: any UsageMeter, dailyCapSeconds: Double) {
        self.inner = inner
        self.meter = meter
        self.dailyCapSeconds = dailyCapSeconds
    }

    public func synthesize(_ text: String, voice: VoiceProfile,
                           context: RequestContext) async throws -> VoiceArtifact {
        let usage = try await meter.currentUsage(for: context.stationID)
        guard usage.generatedSeconds < dailyCapSeconds else {
            throw VoiceError.dailyBudgetExceeded(
                limitSeconds: dailyCapSeconds, usedSeconds: usage.generatedSeconds)
        }

        let artifact = try await inner.synthesize(text, voice: voice, context: context)

        try await meter.record(UsageRecord(
            userID: context.stationID,
            provider: artifact.provider,
            characters: text.count,
            generatedSeconds: artifact.durationSeconds,
            estimatedBillableUnits: artifact.billableUnits,
            observedCost: nil
        ))
        return artifact
    }
}

/// Test double that synthesizes deterministic artifacts (no network, no keys).
public struct MockVoiceProvider: VoiceProvider {
    public let artifactDurationSeconds: Double
    public let failWith: Error?

    public init(artifactDurationSeconds: Double = 2.0, failWith: Error? = nil) {
        self.artifactDurationSeconds = artifactDurationSeconds
        self.failWith = failWith
    }

    public func synthesize(_ text: String, voice: VoiceProfile,
                           context: RequestContext) async throws -> VoiceArtifact {
        if let failWith {
            throw failWith
        }
        return VoiceArtifact(
            data: Data(repeating: 0, count: 10),
            durationSeconds: artifactDurationSeconds,
            billableUnits: text.count,
            provider: "mock",
            cacheKey: nil
        )
    }
}