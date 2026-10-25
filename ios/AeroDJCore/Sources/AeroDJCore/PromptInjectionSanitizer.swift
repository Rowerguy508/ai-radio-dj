import Foundation

/// Defends against prompt injection in imported text (Share, Obsidian, shared
/// email/messages). Redacts instruction-like phrases and strips invisible
/// characters before anything is narrated or handed to a future LLM step.
/// A heuristic, not a guarantee: downstream code must still treat item text as
/// data, never as instructions.
///
/// Originally written by -Claudio in #41; extracted and adapted by Fry.
public struct PromptInjectionSanitizer: Sendable {
    public static let redaction = "[redacted]"

    public init() {}

    /// Instruction-like patterns that should never be narrated or reach an LLM.
    /// The first eight are from #41, with `\s+` instead of single spaces.
    private static let patterns: [String] = [
        #"(?i)ignore\s+(all\s+)?(previous|prior)\s+(instructions|prompts)"#,
        #"(?i)system\s+prompt"#,
        #"(?i)you\s+are\s+now"#,
        #"(?i)disregard\s+(all\s+)?(previous|prior)"#,
        #"(?i)forget\s+(everything|all)\s+(you\s+)?(know|learned)"#,
        #"(?i)act\s+as\s+(if\s+)?(an?\s+)?(assistant|agent|ai)"#,
        #"(?i)reveal\s+(your|the)\s+(system\s+)?(prompt|instructions)"#,
        #"(?i)output\s+(your|the)\s+(system\s+)?(prompt|instructions)"#,
        // Chat-template role markers.
        #"<\|[^|>]{1,32}\|>"#,
        #"(?im)^\s*(system|assistant|developer)\s*:"#,
    ]

    /// Zero-width and bidi-control characters can hide text from the user
    /// while still reaching a model, so they are always removed.
    private static let invisible: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    /// Returns true if the text contains instruction-like content.
    public func isSuspicious(_ text: String) -> Bool {
        let visible = Self.stripInvisible(text)
        return Self.patterns.contains { visible.range(of: $0, options: .regularExpression) != nil }
    }

    /// Removes invisible characters and redacts suspicious spans.
    public func sanitize(_ text: String) -> String {
        var result = Self.stripInvisible(text)
        for pattern in Self.patterns {
            result = result.replacingOccurrences(of: pattern, with: Self.redaction, options: .regularExpression)
        }
        return result
    }

    /// Sanitizes title and summary; id, consent, sensitivity, expiry and
    /// provenance are unchanged. Apply before any `BriefingPlanner`.
    public func sanitized(_ item: ContextItem) -> ContextItem {
        ContextItem(id: item.id, source: item.source, createdAt: item.createdAt, eventAt: item.eventAt,
                    title: sanitize(item.title), summary: sanitize(item.summary),
                    sensitivity: item.sensitivity, consent: item.consent,
                    expiresAt: item.expiresAt, provenance: item.provenance)
    }

    static func stripInvisible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !invisible.contains($0) }))
    }
}
