import Foundation

/// How to say a name the on-device voice gets wrong.
public enum PronunciationKind: Equatable, Sendable {
    /// IPA, for voices that honor it (an SSML `phoneme` or `AVSpeechSynthesisIPANotationAttribute`).
    case ipa(String)
    /// Plain respelling ("Shah-day"): the text itself is replaced, so it works on every voice and
    /// adds no markup. Prefer this unless a listening test shows IPA is needed.
    case respelling(String)
}

/// One name and how to say it.
public struct PronunciationHint: Equatable, Sendable {
    public let term: String
    public let kind: PronunciationKind

    static let maxLength = 80

    public init?(term: String, ipa: String) {
        guard let term = Self.cleanTerm(term), let ipa = Self.cleanValue(ipa) else { return nil }
        self.term = term
        self.kind = .ipa(ipa)
    }

    public init?(term: String, respelling: String) {
        guard let term = Self.cleanTerm(term), let respelling = Self.cleanValue(respelling) else { return nil }
        self.term = term
        self.kind = .respelling(respelling)
    }

    private static func cleanTerm(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxLength, !t.unicodeScalars.contains(where: isControl) else { return nil }
        return t
    }

    /// The replacement is later written into SSML attributes and text, so markup characters,
    /// quotes, ampersands and control characters are refused outright.
    private static func cleanValue(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxLength,
              !t.unicodeScalars.contains(where: { isControl($0) || "<>&\"'".unicodeScalars.contains($0) })
        else { return nil }
        return t
    }

    private static func isControl(_ u: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(u) || u == "\n" || u == "\r"
    }
}

/// A run of speech after hints are applied.
public enum PronouncedSegment: Equatable, Sendable {
    case text(String)
    /// `text` is the name as written (kept for captions and fallbacks); `ipa` is how to say it.
    case ipa(text: String, ipa: String)
}

/// Maps artist and title names to pronunciation hints and applies them to on-device speech.
///
/// A pure text transform: no I/O, no logging, nothing leaves the device. Matching ignores case,
/// accents and curly apostrophes, collapses whitespace, and only matches whole names ("Sade" does
/// not match inside "Persuade"). The longest name wins where two overlap. Hints are only ever
/// applied to the on-device route; cloud voices get the text unchanged.
public struct PronunciationHintTable: Sendable {
    public let hints: [PronunciationHint]
    private let matchers: [Matcher]

    private struct Matcher: Sendable {
        let folded: [String]
        let hint: PronunciationHint
        let startsAlnum: Bool
        let endsAlnum: Bool
    }

    /// Later hints replace earlier ones for the same name (case, accents and spacing ignored).
    public init(_ hints: [PronunciationHint]) {
        var byKey: [[String]: PronunciationHint] = [:]
        var order: [[String]] = []
        for hint in hints {
            let key = Self.fold(Array(hint.term))
            if byKey[key] == nil { order.append(key) }
            byKey[key] = hint
        }
        let unique = order.compactMap { key in byKey[key].map { (key, $0) } }
        self.hints = unique.map(\.1)
        self.matchers = unique.map { key, hint in
            Matcher(folded: key, hint: hint,
                    startsAlnum: hint.term.first.map(Self.isWordCharacter) ?? false,
                    endsAlnum: hint.term.last.map(Self.isWordCharacter) ?? false)
        }.sorted { $0.folded.count > $1.folded.count }
    }

    public static let empty = PronunciationHintTable([])

    /// Names the stock on-device voices are known to mangle. Respelling only, so it adds no markup and
    /// behaves the same on every voice. Not yet verified by ear on a device: a listening pass on the
    /// Duo is still needed (#197), and entries here are meant to be edited after it.
    public static let standard = PronunciationHintTable([
        ("Sade", "Shah-day"),
        ("Beyoncé", "Bee-yon-say"),
        ("Billie Eilish", "Billie Eye-lish"),
        ("Kehlani", "Kuh-lah-nee"),
        ("SZA", "Siz-uh"),
        ("Dua Lipa", "Doo-ah Lee-pah"),
        ("Lil Nas X", "Lil Naz Ex"),
        ("Deadmau5", "dead mouse"),
        ("AC/DC", "A C D C"),
        ("Björk", "Byerk"),
        ("Mötley Crüe", "Motley Crew"),
    ].compactMap { PronunciationHint(term: $0.0, respelling: $0.1) })

    /// This table plus `other`; `other` wins on the same name.
    public func merging(_ other: PronunciationHintTable) -> PronunciationHintTable {
        PronunciationHintTable(hints + other.hints)
    }

    public var isEmpty: Bool { hints.isEmpty }

    /// The text split into plain runs and IPA-hinted names. Respellings are already substituted
    /// into the plain runs. Without any match this is one `.text` segment holding `text` unchanged.
    public func segments(in text: String) -> [PronouncedSegment] {
        let chars = Array(text)
        guard !matchers.isEmpty, !chars.isEmpty else { return chars.isEmpty ? [] : [.text(text)] }
        let folded = Self.fold(chars)
        var out: [PronouncedSegment] = []
        var pending = ""
        var i = 0
        while i < chars.count {
            if let (matcher, length) = match(at: i, chars: chars, folded: folded) {
                switch matcher.hint.kind {
                case .respelling(let spoken):
                    pending += spoken
                case .ipa(let ipa):
                    if !pending.isEmpty { out.append(.text(pending)); pending = "" }
                    out.append(.ipa(text: String(chars[i..<(i + length)]), ipa: ipa))
                }
                i += length
            } else {
                pending.append(chars[i])
                i += 1
            }
        }
        if !pending.isEmpty { out.append(.text(pending)) }
        return out
    }

    /// True when `text` contains a name this table changes.
    public func applies(to text: String) -> Bool {
        !text.isEmpty && segments(in: text) != [.text(text)]
    }

    /// Plain text with respellings substituted. IPA hints cannot be written in plain text, so those
    /// names stay as written; use `segments(in:)` where the engine takes IPA.
    public func applying(toPlainText text: String) -> String {
        segments(in: text).map { segment in
            switch segment {
            case .text(let s): s
            case .ipa(let written, _): written
            }
        }.joined()
    }

    /// SSML (the output of `SpeechDelivery.ssml`) with hints applied inside its text runs only: tags
    /// are never touched, respellings replace the name, and IPA names are wrapped in
    /// `<phoneme alphabet="ipa" ph="...">`. Changed text is re-escaped. A run holding a numeric
    /// character reference (`&#...`) is left alone rather than risk re-encoding it. SSML with no
    /// match is returned unchanged, character for character.
    public func applying(toSSML ssml: String) -> String {
        guard !matchers.isEmpty else { return ssml }
        var out = ""
        var run = ""
        var inTag = false
        for ch in ssml {
            if inTag {
                out.append(ch)
                if ch == ">" { inTag = false }
            } else if ch == "<" {
                out += hintedRun(run)
                run = ""
                out.append(ch)
                inTag = true
            } else {
                run.append(ch)
            }
        }
        out += hintedRun(run)
        return out
    }

    private func hintedRun(_ run: String) -> String {
        guard !run.isEmpty, !run.contains("&#") else { return run }
        let plain = Self.unescape(run)
        let pieces = segments(in: plain)
        guard pieces != [.text(plain)] else { return run }
        return pieces.map { piece in
            switch piece {
            case .text(let s): Self.escape(s)
            case .ipa(let written, let ipa): "<phoneme alphabet=\"ipa\" ph=\"\(ipa)\">\(Self.escape(written))</phoneme>"
            }
        }.joined()
    }

    // MARK: matching

    private func match(at i: Int, chars: [Character], folded: [String]) -> (Matcher, Int)? {
        for matcher in matchers {
            let n = matcher.folded.count
            guard i + n <= chars.count else { continue }
            if matcher.startsAlnum, i > 0, Self.isWordCharacter(chars[i - 1]) { continue }
            if matcher.endsAlnum, i + n < chars.count, Self.isWordCharacter(chars[i + n]) { continue }
            if folded[i..<(i + n)].elementsEqual(matcher.folded) { return (matcher, n) }
        }
        return nil
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Case, accent, whitespace-kind and apostrophe-style insensitive, one entry per Character so
    /// indexes line up with the original text.
    private static func fold(_ chars: [Character]) -> [String] {
        chars.map { c in
            if c.isWhitespace { return " " }
            if c == "\u{2019}" || c == "\u{2018}" || c == "\u{02BC}" { return "'" }
            return String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
