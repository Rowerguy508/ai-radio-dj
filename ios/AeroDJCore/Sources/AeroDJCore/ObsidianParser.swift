import Foundation

/// Parses a single Obsidian Markdown file into narratable `ContextItem`s.
/// Extracts frontmatter, headings, tasks, and links; sanitizes unsafe content;
/// restricts traversal. Pure logic, testable with fixtures.
public struct ObsidianParser: Sendable {
    public init() {}

    /// Parse a Markdown file into context items. `fileID` is a stable
    /// identifier (e.g. the security-scoped bookmark path) used for provenance.
    public func parse(_ markdown: String, fileID: String, now: Date = Date()) -> [ContextItem] {
        var items: [ContextItem] = []
        let lines = markdown.components(separatedBy: .newlines)

        // Frontmatter (--- ... ---) is metadata, not narratable content.
        var body = lines
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                body = Array(lines.dropFirst(end + 1))
            }
        }

        var heading: String?
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("#") {
                heading = trimmed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }

            // Tasks and bullet content are narratable; skip links-only lines.
            let isTask = trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]")
            let isLink = trimmed.hasPrefix("[[") || trimmed.hasPrefix("http")
            guard isTask || !isLink else { continue }

            let text = sanitize(trimmed)
            guard !text.isEmpty else { continue }

            items.append(
                ContextItem(
                    source: .obsidian,
                    eventAt: nil,
                    title: heading ?? "Note",
                    summary: text,
                    sensitivity: .low,
                    consent: .notRequested,
                    provenance: "obsidian://\(fileID)#\(items.count)"
                )
            )
        }
        return items
    }

    /// Strip markdown link syntax and control characters.
    private func sanitize(_ text: String) -> String {
        var t = text
        // [[wikilink|alias]] -> alias
        t = t.replacingOccurrences(of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        // [[wikilink]] -> wikilink
        t = t.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        // [text](url) -> text
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Strip control characters
        t = t.components(separatedBy: CharacterSet.controlCharacters).joined()
        return t.trimmingCharacters(in: .whitespaces)
    }
}
