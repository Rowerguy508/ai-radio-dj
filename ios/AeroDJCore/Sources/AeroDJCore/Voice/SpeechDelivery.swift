import Foundation

/// Natural delivery for briefing text: radio-style times, short pauses
/// between sentences, and SSML for providers that accept it. Pure text
/// transforms; never adds or removes facts.
public enum SpeechDelivery {
    /// Pause after each sentence and after a lead-in colon, in milliseconds.
    public static let sentencePauseMs = 300
    public static let leadPauseMs = 150

    /// Plain text tuned for TTS: "12 PM" -> "noon", "9:00 AM" -> "9 a.m.",
    /// "9:30 AM" -> "9:30 a.m.", so engines don't spell "AM" or say "o'clock zero zero".
    public static func speakable(_ text: String) -> String {
        var s = text
        s = replace(#"\b12(?::00)?\s?PM\b"#, in: s, with: "noon")
        s = replace(#"\b12(?::00)?\s?AM\b"#, in: s, with: "midnight")
        s = replace(#"\b(\d{1,2}):00\s?(AM|PM)\b"#, in: s, with: "$1 $2")
        s = replace(#"\b(\d{1,2}(?::\d{2})?)\s?AM\b"#, in: s, with: "$1 a.m.")
        s = replace(#"\b(\d{1,2}(?::\d{2})?)\s?PM\b"#, in: s, with: "$1 p.m.")
        // "a.m.." when the time ends a sentence.
        s = s.replacingOccurrences(of: "m..", with: "m.")
        return s
    }

    /// The only audio tags a tag-reading voice (ElevenLabs v3/v4) may receive. The same list the
    /// proxy allows. No route turns tags on: `VoiceRoute.supportsAudioTags` defaults to false.
    public static let allowedAudioTags = ["warmly", "relaxed", "chuckles", "softly", "excited"]

    /// `speakable` for a route that leaves the device. Square brackets never reach that voice as
    /// text: a title like "Song [Live]" becomes "Song Live", so nothing a title contains can
    /// become an audio tag. With `keepingAudioTags` (a route whose `supportsAudioTags` is on) an
    /// exact allowlisted tag such as `[warmly]` survives; every other bracket is still removed.
    /// Text without brackets is returned exactly as `speakable`, so cache keys of bracket-free
    /// lines do not move.
    public static func speakable(_ text: String, keepingAudioTags: Bool) -> String {
        let spoken = speakable(text)
        guard spoken.contains("[") || spoken.contains("]") else { return spoken }
        guard keepingAudioTags, let kept = keepingAllowlistedTags(spoken) else { return stripBracketCharacters(spoken) }
        return kept
    }

    /// `[` and `]` become spaces, then whitespace is collapsed. Inner words stay, so "Song [Live]."
    /// is "Song Live ." — the same substitution the voice proxy applies before any model sees the line.
    private static func stripBracketCharacters(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Allowlisted tags survive as `[tag]`; every other bracket character is removed. Nil if the
    /// pattern cannot be compiled, so the caller strips every bracket instead of sending one.
    private static func keepingAllowlistedTags(_ spoken: String) -> String? {
        let pattern = #"\[\s*("# + allowedAudioTags.joined(separator: "|") + #")\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = spoken as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: spoken, range: NSRange(location: 0, length: ns.length)) {
            out += stripBracketCharacters(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            out += " [\(ns.substring(with: match.range(at: 1)).lowercased())] "
            last = match.range.location + match.range.length
        }
        out += stripBracketCharacters(ns.substring(from: last))
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// SSML 1.1 subset (`speak`, `break`) accepted by AVSpeechUtterance(ssmlRepresentation:)
    /// and SSML-capable cloud voices. Text is XML-escaped.
    public static func ssml(_ text: String) -> String {
        let spoken = speakable(text)
        var out = ""
        var index = spoken.startIndex
        while index < spoken.endIndex {
            let ch = spoken[index]
            out += escape(ch)
            let next = spoken.index(after: index)
            let atBoundary = next == spoken.endIndex || spoken[next] == " "
            if atBoundary, next != spoken.endIndex {
                if ch == ":" { out += "<break time=\"\(leadPauseMs)ms\"/>" }
                else if ch == "." || ch == "!" || ch == "?", !endsWithAbbreviation(spoken[..<next]),
                        spoken[next...].dropFirst().first.map({ $0.isUppercase || $0.isNumber }) == true {
                    out += "<break time=\"\(sentencePauseMs)ms\"/>"
                }
            }
            index = next
        }
        return "<speak>\(out)</speak>"
    }

    /// Inverse of `ssml` for engines that can't parse it.
    public static func plainText(fromSSML ssml: String) -> String {
        replace("<[^>]+>", in: ssml, with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func endsWithAbbreviation(_ s: Substring) -> Bool {
        ["Dr.", "Mr.", "Mrs.", "Ms.", "St.", "vs."].contains { s.hasSuffix($0) }
    }

    private static func escape(_ ch: Character) -> String {
        switch ch {
        case "&": "&amp;"
        case "<": "&lt;"
        case ">": "&gt;"
        case "\"": "&quot;"
        case "'": "&apos;"
        default: String(ch)
        }
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
