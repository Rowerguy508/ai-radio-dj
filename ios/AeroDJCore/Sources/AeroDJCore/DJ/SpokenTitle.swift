import Foundation

/// Light cleanup of track metadata before the DJ says it. MusicKit titles often carry catalog
/// suffixes a radio host would never read aloud: "(Remastered 2011)", " - 2009 Remaster",
/// "[Explicit]", "(Deluxe Edition)". Those are dropped. A featured artist is kept and spoken
/// naturally: "(feat. X)" becomes "featuring X"; "(with X)" is left as written, since it is not
/// always an artist credit ("(with Strings)"). Nothing is added: the result only ever
/// contains words that were already in the metadata (narration reliability, not a feature).
/// If cleanup would leave nothing, the original text is spoken unchanged.
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
        text = replace(text, #"\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+?)\s*[\)\]]"#) { " featuring " + $0[0] }
        text = replace(text, #"\s*[\(\[]([^\)\]]*)[\)\]]"#) { isCatalogTag($0[0]) ? "" : nil }
        text = replace(text, #"\s+[-–—]\s+([^-–—]+)$"#) { isCatalogTag($0[0]) ? "" : nil }
        text = replace(text, #"\s+(?:feat\.|ft\.)\s+"#) { _ in " featuring " }
        text = collapse(text)
        return text.isEmpty ? original : text
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
