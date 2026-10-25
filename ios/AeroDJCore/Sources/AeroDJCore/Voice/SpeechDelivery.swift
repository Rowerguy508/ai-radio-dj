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
