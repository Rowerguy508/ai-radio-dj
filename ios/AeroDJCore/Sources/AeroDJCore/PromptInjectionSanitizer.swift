import Foundation

/// Two jobs for imported text (Share, Obsidian, shared email/messages):
///
/// 1. **Speakable cleanup** (`sanitize`): strips invisible/smuggling characters,
///    chat-template role markers, URLs, HTML and Markdown markup, so a TTS voice
///    never reads markup aloud. It never inserts placeholders and never edits
///    the user's words.
/// 2. **Flag, don't rewrite** (`isSuspicious`): instruction-like text marks the
///    item for re-review (`sanitized` drops its consent to `.notRequested` and
///    raises sensitivity to `.high`) until the user confirms it on the review
///    screen. Matching runs on NFKC-normalized, homoglyph-folded text.
///
/// A heuristic, not a security boundary: paraphrases and other languages get
/// through. The real defense for any LLM step is structural (templates with
/// slots; untrusted fields never pass through the model — see #43's
/// `BriefingRewriteGuard`). Downstream code must treat item text as data.
///
/// Originally written by -Claudio in #41; extracted and adapted by Fry.
public struct PromptInjectionSanitizer: Sendable {
    public init() {}

    /// Instruction-like patterns, matched on folded text. Tuned to avoid
    /// everyday phrasing ("you are now checked in", "System: maintenance").
    private static let patterns: [String] = [
        #"(?i)\b(ignore|disregard|forget|override|bypass)\s+(all\s+|any\s+|the\s+|your\s+)?(previous|prior|above|earlier|preceding)\s+(instructions|prompts|rules|messages|directions)"#,
        #"(?i)\b(disregard|forget)\s+(all\s+|everything\s+)?(previous|prior|above)\b"#,
        #"(?i)\bpay\s+no\s+attention\s+to\s+(what|the)\s+(you\s+were\s+told|instructions)"#,
        #"(?i)\bsystem\s+prompt\b"#,
        #"(?i)\byou\s+are\s+now\s+(a|an|the|my|in|no\s+longer|free|unrestricted|jailbroken|dan)\b"#,
        #"(?i)\bforget\s+(everything|all)\s+(you\s+)?(know|learned|were\s+told)"#,
        #"(?i)\bact\s+as\s+(if\s+)?(you\s+are\s+)?(an?\s+)?(unrestricted\s+|jailbroken\s+|different\s+)?(ai|assistant|agent|chatbot|language\s+model)\b(?=\s*($|[.,;:!]|with\b|without\b|that\b|who\b|and\b|from\s+now|named\b|called\b))"#,
        #"(?i)\b(reveal|output|print|repeat)\s+(your|the)\s+(system\s+|hidden\s+|initial\s+)?(prompt|instructions)"#,
        #"(?i)\b(ignora|ignorez|ignoriere)\b.{0,20}\b(instrucciones|instructions|anweisungen)\b"#,
        #"<\|[^|>]{1,32}\|>"#,
        #"(?im)^\s*(system|assistant|developer)\s*:\s*(you|ignore|disregard|forget|act|from\s+now|new\s+instructions)\b"#,
    ]

    /// Returns true if the text contains instruction-like content.
    public func isSuspicious(_ text: String) -> Bool {
        let folded = Self.fold(text)
        return Self.patterns.contains { folded.range(of: $0, options: .regularExpression) != nil }
    }

    /// Speakable plain text: invisible characters, role markers, URLs, HTML
    /// tags, Markdown emphasis/heading/quote markers and inline `#tags` are
    /// removed; whitespace collapsed. Never adds placeholder tokens.
    public func sanitize(_ text: String) -> String {
        var s = Self.stripInvisible(text).precomposedStringWithCompatibilityMapping
        s = s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        let removals = [
            #"<\|[^|>]{1,32}\|>"#,                       // chat-template role markers
            #"<[^>\n]{1,200}>"#,                         // HTML tags
            #"(?i)\b(?:https?|ftp)://\S+"#, #"(?i)\bwww\.\S+"#,
            #"(?m)^\s{0,3}(#{1,6}|>+|[-*+])\s+"#,        // heading / quote / bullet markers
            #"(?:^|(?<=\s))#[A-Za-z][\w/-]*"#,           // inline tags
            #"\*\*|__|~~|==|`+"#,
        ]
        for pattern in removals {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Single-character emphasis at word boundaries; keeps snake_case and 2*3.
        s = s.replacingOccurrences(of: #"(?<![\w*])[*_](?=\S)([^*_\n]*?\S)[*_](?![\w*])"#, with: "$1",
                                   options: .regularExpression)
        return s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
    }

    /// Cleans title and summary for speech. A suspicious item is flagged, not
    /// rewritten: consent becomes `.notRequested` (so it is never narrated) and
    /// sensitivity `.high`, unless the user already re-confirmed it
    /// (`reconfirmed` contains its id). id, expiry and provenance are unchanged.
    public func sanitized(_ item: ContextItem, reconfirmed: Set<UUID> = []) -> ContextItem {
        let flagged = !reconfirmed.contains(item.id) && (isSuspicious(item.title) || isSuspicious(item.summary))
        return ContextItem(id: item.id, source: item.source, createdAt: item.createdAt, eventAt: item.eventAt,
                           title: sanitize(item.title), summary: sanitize(item.summary),
                           sensitivity: flagged && item.sensitivity != .blocked ? .high : item.sensitivity,
                           consent: flagged && item.consent == .granted ? .notRequested : item.consent,
                           expiresAt: item.expiresAt, provenance: item.provenance)
    }

    /// Invisible in UI but tokenized by models, so always removed: zero-width
    /// and bidi controls, soft hyphen, CGJ, Mongolian vowel separator, Unicode
    /// tag characters (U+E0000–E007F, "ASCII smuggling") and variation
    /// selectors except U+FE0F (emoji presentation).
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF,
             0x00AD, 0x034F, 0x180E, 0xFE00...0xFE0E, 0xE0000...0xE007F, 0xE0100...0xE01EF:
            return true
        default:
            return scalar.properties.generalCategory == .control && !"\n\t".unicodeScalars.contains(scalar)
        }
    }

    static func stripInvisible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisible($0) }))
    }

    /// Matching form: invisible stripped, NFKC (fullwidth → ASCII), common
    /// Cyrillic/Greek look-alikes and leetspeak digits folded to Latin.
    static func fold(_ text: String) -> String {
        let map: [Character: Character] = [
            "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j",
            "ѕ": "s", "ԁ": "d", "ɡ": "g", "ո": "n", "Α": "A", "Ε": "E", "Ι": "I", "Ο": "O", "ο": "o",
            "ι": "i", "ν": "v", "А": "A", "Е": "E", "О": "O", "Р": "P", "С": "C", "І": "I",
        ]
        let normalized = stripInvisible(text).precomposedStringWithCompatibilityMapping
        var folded = String(normalized.map { map[$0] ?? $0 })
        // Leetspeak inside words only (keeps "9:30", "IB 3166").
        folded = folded.replacingOccurrences(of: #"(?<=[A-Za-z])0|0(?=[A-Za-z])"#, with: "o", options: .regularExpression)
        folded = folded.replacingOccurrences(of: #"(?<=[A-Za-z])[1!](?=[A-Za-z])"#, with: "i", options: .regularExpression)
        folded = folded.replacingOccurrences(of: #"(?<=[A-Za-z])3(?=[A-Za-z])"#, with: "e", options: .regularExpression)
        return folded
    }
}
