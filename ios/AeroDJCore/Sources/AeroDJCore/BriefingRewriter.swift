import Foundation

/// Voice/style a rewriter is asked to use.
public struct BriefingStyle: Equatable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
    public static let calmDJ = BriefingStyle(name: "calm-dj")
}

/// Boundary for a future LLM restyling step. Implementations receive one
/// segment's structured fields only (never other items) and must treat
/// `title`/`detail` as untrusted data, not instructions. Not implemented here;
/// any networked implementation must keep secrets server-side.
public protocol BriefingRewriter: Sendable {
    func rewrite(_ segment: BriefingScriptSegment, style: BriefingStyle) async throws -> String
}

/// Applies a rewriter but keeps the templated text whenever the rewrite fails,
/// is empty, grows too much, introduces numbers absent from the original, or
/// would push the briefing over its spoken budget. Provenance never changes.
public struct BriefingRewriteGuard: Sendable {
    public let maxWordGrowth: Double
    public let maxSpokenSeconds: Int

    public init(maxWordGrowth: Double = 1.5, maxSpokenSeconds: Int = 150) {
        self.maxWordGrowth = maxWordGrowth
        self.maxSpokenSeconds = maxSpokenSeconds
    }

    public func restyle(_ script: BriefingScript, with rewriter: any BriefingRewriter,
                        style: BriefingStyle = .calmDJ) async -> (script: BriefingScript, fallbacks: Int) {
        var segments = script.segments
        var fallbacks = 0
        for index in segments.indices {
            let original = segments[index]
            guard let text = try? await rewriter.rewrite(original, style: style), accepts(text, for: original) else {
                fallbacks += 1
                continue
            }
            let candidate = original.replacingText(text)
            let total = segments.reduce(0) { $0 + $1.estimatedSpokenSeconds }
                - original.estimatedSpokenSeconds + candidate.estimatedSpokenSeconds
            if total <= maxSpokenSeconds { segments[index] = candidate } else { fallbacks += 1 }
        }
        let restyled = BriefingScript(segments: segments, excluded: script.excluded,
                                      unavailableSources: script.unavailableSources,
                                      experienceSeconds: script.experienceSeconds)
        return (restyled, fallbacks)
    }

    func accepts(_ text: String, for original: BriefingScriptSegment) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let words = Double(trimmed.split(whereSeparator: \.isWhitespace).count)
        let originalWords = Double(original.text.split(whereSeparator: \.isWhitespace).count)
        guard words <= (originalWords * maxWordGrowth).rounded(.up) else { return false }
        return Self.numbers(in: trimmed).isSubset(of: Self.numbers(in: original.text))
    }

    static func numbers(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isNumber }).map(String.init))
    }
}
