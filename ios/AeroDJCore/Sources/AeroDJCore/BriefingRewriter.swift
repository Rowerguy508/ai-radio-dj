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
/// is empty, grows too much, introduces numbers absent from the original,
/// drops or alters a fact (title, detail, time phrase and attribution must
/// appear verbatim), adds any word outside a small neutral vocabulary (so
/// "confirmed" can't become "canceled"), or would push the briefing over its
/// spoken budget. Provenance never changes. Conservative by design: v1 falls
/// back to the deterministic template. No LLM rewriter is enabled; any future
/// one must also restyle template words only (slots), never untrusted fields.
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
        guard Self.numbers(in: trimmed).isSubset(of: Self.numbers(in: original.text)) else { return false }
        var facts = [original.title, original.detail, original.timePhrase].compactMap { $0 }.filter { !$0.isEmpty }
        if let source = original.source { facts.append("From \(MorningBriefingEngine.attribution(source))") }
        for fact in facts where trimmed.range(of: fact, options: .caseInsensitive) == nil { return false }
        let added = Self.words(in: trimmed).subtracting(Self.words(in: original.text))
        return added.isSubset(of: Self.neutralWords)
    }

    /// Words a restyle may add: connective, tone-only, no facts or negations.
    static let neutralWords: Set<String> = [
        "a", "an", "the", "and", "so", "then", "also", "just", "now", "next", "here", "there", "it's", "it",
        "is", "you", "your", "you've", "you're", "got", "have", "on", "for", "to", "of", "at", "in", "with",
        "hey", "hi", "hello", "okay", "alright", "well", "easy", "does", "quick", "heads", "up", "reminder",
        "friendly", "folks", "everyone", "friend", "lovely", "bright", "early", "listening", "this", "that's",
        "let's", "start", "kick", "off", "first", "lastly", "finally", "plus", "after", "music", "back",
    ]

    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init))
    }

    static func numbers(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isNumber }).map(String.init))
    }
}
