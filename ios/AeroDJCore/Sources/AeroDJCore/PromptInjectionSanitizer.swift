import Foundation

/// Defends against prompt injection in imported text. Strips instruction-like
/// content and control tokens before anything is narrated or sent to an LLM.
public struct PromptInjectionSanitizer: Sendable {
    public init() {}

    /// Instruction-like patterns that should never be narrated or reach an LLM.
    private static let patterns: [String] = [
        #"(?i)ignore (all )?(previous|prior) (instructions|prompts)"#,
        #"(?i)system prompt"#,
        #"(?i)you are now"#,
        #"(?i)disregard (all )?(previous|prior)"#,
        #"(?i)forget (everything|all) (you )?(know|learned)"#,
        #"(?i)act as (if )?(an? )?(assistant|agent|ai)"#,
        #"(?i)reveal (your|the) (system )?(prompt|instructions)"#,
        #"(?i)output (your|the) (system )?(prompt|instructions)"#,
    ]

    /// Returns true if the text contains instruction-like content.
    public func isSuspicious(_ text: String) -> Bool {
        Self.patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Redact suspicious spans; returns sanitized text.
    public func sanitize(_ text: String) -> String {
        var result = text
        for pattern in Self.patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }
}
