import Foundation

/// Light cleanup of track metadata before the DJ says it. MusicKit titles often carry catalog
/// suffixes a radio host would never read aloud: "(Remastered 2011)", " - 2009 Remaster",
/// "[Explicit]", "(Deluxe Edition)". Those are dropped. A featured artist is kept and spoken
/// naturally: "(feat. X)" becomes "featuring X"; "(with X)" keeps its words, since it is not
/// always an artist credit ("(with Strings)"). Nothing is added: the result only ever
/// contains words that were already in the metadata (narration reliability, not a feature).
/// If cleanup would leave nothing, the original text is spoken unchanged.
///
/// Kept version tags are spoken without their brackets (-Echo): a trailing "(Live 2014)",
/// "[Acoustic]" or a dash suffix naming the recording (" - Live 2011 Remaster") becomes
/// ", Live 2014", so a voice never reads or stumbles over brackets. Several trailing tags become
/// a comma chain ("Song, Live, Acoustic"). Casing is preserved exactly as written: no word is
/// lowercased, so proper nouns ("Clean Bandit Remix") stay intact. Only trailing tags are
/// rewritten; a title that is only a bracket, or text whose brackets are nested or unbalanced,
/// keeps its kept tags as written rather than mangled (catalog tags still drop). A title that
/// ends with "!", "?" or "." takes no comma before its tags: "Help! (Live)" is "Help! Live".
public enum SpokenTitle {
    /// Catalog-only tags. A bracketed or dash suffix is dropped only when it is exactly one of
    /// these, ignoring years and ordinals, optionally followed by "version" ("Clean Version").
    /// Anything mentioning remix, mix, live, acoustic or demo is always kept: it says which
    /// recording it is ("Clean Bandit Remix", "Live 2011 Remaster").
    static let catalogTags = [
        "remaster", "remastered", "explicit", "clean", "deluxe", "deluxe edition", "bonus track", "bonus",
        "album version", "single version", "lp version", "mono", "stereo", "anniversary edition",
        "expanded edition", "special edition", "edition", "digitally remastered", "digital remaster",
        "super deluxe edition", "remasterizado",
    ]

    /// The title as it should be spoken.
    public static func clean(_ raw: String) -> String {
        let original = collapse(raw)
        var text = original
        // Only innermost, same-kind groups: a nested group is never cut in half ("Song (Remastered [2011])").
        text = replace(text, #"\s*(?:\(\s*(?:feat\.?|ft\.?|featuring)\s+([^\(\)\[\]]+?)\s*\)|\[\s*(?:feat\.?|ft\.?|featuring)\s+([^\(\)\[\]]+?)\s*\])"#) {
            " featuring " + ($0[0].isEmpty ? $0[1] : $0[0])
        }
        text = replace(text, #"\s*(?:\(([^\(\)\[\]]*)\)|\[([^\(\)\[\]]*)\])"#) { isCatalogTag($0[0].isEmpty ? $0[1] : $0[0]) ? "" : nil }
        // A dash suffix that would end inside a bracket group ("Song (Dreams - 2004 Remaster)") is not a suffix.
        text = replace(text, #"\s+[-–—]\s+([^-–—]+)$"#) { isCatalogTag($0[0]) && bracketsAreWellFormed($0[0]) ? "" : nil }
        text = replace(text, #"\s+(?:feat\.|ft\.)\s+"#) { _ in " featuring " }
        // Stray separators after the last tag ("Song (Live) ,") go first, so the tag still ends the title.
        text = collapse(text)
        while let last = text.last, ",;:".contains(last) { text.removeLast() }
        text = speakKeptTags(collapse(text))
        // A dangling comma would meet the template's own punctuation ("{title}." -> ", ." or ",,").
        while text.last == "," { text.removeLast() }
        text = collapse(text)
        return text.isEmpty ? original : text
    }

    /// Rewrites the trailing kept tags as a comma chain: "Song (Live) [Acoustic]" becomes
    /// "Song, Live, Acoustic"; "Song - Live 2011 Remaster" becomes "Song, Live 2011 Remaster".
    /// Same words, same order, same case; only brackets and the dash become commas. A dash
    /// suffix is rewritten only when it names the recording (remix, mix, live, acoustic, demo),
    /// so titles like "Re-Make - Re-Model" are untouched. If no title text would be left outside
    /// brackets ("(Live)", "(Live) (Remix)"), the text is returned unchanged.
    static func speakKeptTags(_ text: String) -> String {
        // Nested or unbalanced brackets: any rewrite could cut words, so the tags stay as written.
        // Only this rewrite is skipped; catalog tags and "feat." were already handled by `clean`.
        guard bracketsAreWellFormed(text) else { return text }
        var head = text
        var tags: [String] = []
        while true {
            if let (rest, inner) = trailingBracket(head) {
                head = rest
                let tag = trimTag(inner)
                if !tag.isEmpty { tags.insert(tag, at: 0) }
            } else if let (rest, inner) = trailingRecordingDash(head) {
                head = rest
                let tag = trimTag(inner)
                if !tag.isEmpty { tags.insert(tag, at: 0) }
            } else {
                break
            }
        }
        guard head != text else { return text }
        head = collapse(head)
        // Nothing but brackets left (or nothing at all): leave the title as written.
        guard hasTextOutsideBrackets(head) else { return text }
        while let last = head.last, ",;:".contains(last) { head.removeLast() }
        head = collapse(head)
        guard !head.isEmpty else { return text }
        guard !tags.isEmpty else { return head }   // only empty brackets: "Song ()" is "Song"
        // A title that already ends a sentence ("Help!", "Song.") takes no comma: "Help! Live".
        let joiner = head.last.map { "!?.".contains($0) } == true ? " " : ", "
        return head + joiner + tags.joined(separator: ", ")
    }

    /// The last bracket group if the text ends with one: (text before it, inner text).
    private static func trailingBracket(_ text: String) -> (String, String)? {
        let trimmed = collapse(text)
        guard let close = trimmed.last, close == ")" || close == "]" else { return nil }
        let open: Character = close == ")" ? "(" : "["
        guard let openIndex = trimmed.lastIndex(of: open) else { return nil }
        let inner = String(trimmed[trimmed.index(after: openIndex)..<trimmed.index(before: trimmed.endIndex)])
        guard !inner.contains(where: { "()[]".contains($0) }) else { return nil }
        return (String(trimmed[..<openIndex]), inner)
    }

    /// A trailing " - X" / " – X" / " — X" suffix that names the recording.
    private static func trailingRecordingDash(_ text: String) -> (String, String)? {
        let trimmed = collapse(text)
        guard let regex = try? NSRegularExpression(pattern: #"\s+[-–—]\s+([^-–—()\[\]]+)$"#),
              let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length))
        else { return nil }
        let ns = trimmed as NSString
        let inner = ns.substring(with: match.range(at: 1))
        let lower = inner.lowercased()
        guard recordingWords.contains(where: { lower.contains($0) }) else { return nil }
        return (ns.substring(to: match.range.location), inner)
    }

    /// Tag text without surrounding spaces or separator punctuation, so the chain never gets ",,".
    private static func trimTag(_ inner: String) -> String {
        var tag = collapse(inner)
        while let first = tag.first, ",;:".contains(first) { tag.removeFirst() }
        while let last = tag.last, ",;:".contains(last) { tag.removeLast() }
        return collapse(tag)
    }

    private static func hasTextOutsideBrackets(_ text: String) -> Bool {
        var depth = 0
        for char in text {
            if char == "(" || char == "[" { depth += 1 } else if char == ")" || char == "]" { depth -= 1 }
            else if depth == 0, !char.isWhitespace { return true }
        }
        return false
    }

    /// True when every "(" and "[" closes with its own kind and no bracket sits inside another.
    static func bracketsAreWellFormed(_ text: String) -> Bool {
        var open: Character?
        for char in text {
            switch char {
            case "(", "[":
                if open != nil { return false }
                open = char
            case ")":
                if open != "(" { return false }
                open = nil
            case "]":
                if open != "[" { return false }
                open = nil
            default: continue
            }
        }
        return open == nil
    }

    /// An artist credit as it should be spoken: "feat." and "ft." become "featuring".
    public static func cleanArtist(_ raw: String) -> String {
        let original = collapse(raw)
        let text = collapse(replace(original, #"\s+(?:feat\.?|ft\.?)\s+"#) { _ in " featuring " })
        return text.isEmpty ? original : text
    }

    /// Words that name a recording, never a catalog tag (matched anywhere, case-insensitive).
    static let recordingWords = ["remix", "mix", "live", "acoustic", "demo"]

    static func isCatalogTag(_ inner: String) -> Bool {
        let lower = inner.lowercased()
        if recordingWords.contains(where: { lower.contains($0) }) { return false }
        // Years and numbers around the tag ("2011 Remaster", "Remastered 2009", "40th Anniversary Edition").
        let words = lower
            .replacingOccurrences(of: #"\b\d+(st|nd|rd|th)?\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard !words.isEmpty else { return false }
        return catalogTags.contains { words == $0 || words == $0 + " version" }
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Replaces each match of `pattern`. `transform` gets the capture groups and returns the
    /// replacement, or nil to leave that match as it was.
    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let groups = (1..<max(1, match.numberOfRanges)).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            guard let replacement = transform(groups) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + replacement
            cursor = match.range.location + match.range.length
        }
        return out + ns.substring(from: cursor)
    }
}
