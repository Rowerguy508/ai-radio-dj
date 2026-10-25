import Foundation

/// A Markdown note reduced to the parts AeroDJ may narrate. Built by
/// `MarkdownNoteParser`; contains sanitized plain text only, never raw HTML,
/// code blocks, comments or embedded files.
public struct MarkdownNote: Equatable, Sendable {
    public struct Heading: Equatable, Sendable {
        public let level: Int
        public let text: String
    }

    public struct Task: Equatable, Sendable {
        public let text: String
        public let isDone: Bool
    }

    public enum Link: Equatable, Sendable {
        /// `[[target]]` / `[[target#heading|alias]]`. Never followed or read.
        case wiki(target: String)
        /// `[text](https://...)`. Only http(s) URLs are kept.
        case web(URL)
    }

    /// Flat YAML-subset frontmatter: scalars and lists of scalars.
    public let frontmatter: [String: [String]]
    public let headings: [Heading]
    public let tasks: [Task]
    public let links: [Link]
    /// Sanitized prose paragraphs (excludes headings and tasks).
    public let paragraphs: [String]

    public var openTasks: [Task] { tasks.filter { !$0.isDone } }

    /// First value of a frontmatter key (keys are lowercased on parse).
    public func frontmatterValue(_ key: String) -> String? {
        frontmatter[key.lowercased()]?.first
    }
}

/// Pure-Swift, dependency-free parser for the Obsidian Markdown subset AeroDJ
/// needs: YAML frontmatter (flat), ATX headings, checkbox tasks, links and prose.
/// Input is untrusted user content; output is plain text with markup removed.
public struct MarkdownNoteParser: Sendable {
    /// Bounds work done on hostile input.
    public static let maxFrontmatterKeys = 64

    public init() {}

    public func parse(_ source: String) -> MarkdownNote {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = Self.removingDelimited(text, open: "<!--", close: "-->")
        text = Self.removingDelimited(text, open: "%%", close: "%%") // Obsidian private comments

        var lines = text.components(separatedBy: "\n")
        let frontmatter = Self.extractFrontmatter(&lines)

        var headings: [MarkdownNote.Heading] = []
        var tasks: [MarkdownNote.Task] = []
        var links: [MarkdownNote.Link] = []
        var paragraphs: [String] = []
        var current: [String] = []
        var fence: String?

        func flush() {
            let joined = Self.collapse(current.joined(separator: " "))
            if !joined.isEmpty { paragraphs.append(joined) }
            current.removeAll()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                fence = String(line.prefix(3))
                continue
            }
            if line.isEmpty { flush(); continue }

            links.append(contentsOf: Self.links(in: line))

            if let heading = Self.heading(line) {
                flush()
                headings.append(heading)
            } else if let task = Self.task(line) {
                flush()
                tasks.append(task)
            } else {
                current.append(Self.stripBlockMarkers(line))
            }
        }
        flush()

        return MarkdownNote(frontmatter: frontmatter, headings: headings, tasks: tasks,
                            links: links, paragraphs: paragraphs.filter { !$0.isEmpty })
    }

    // MARK: - Frontmatter

    /// Removes a leading `---` ... `---`/`...` block from `lines` and parses it.
    /// An unterminated block is treated as ordinary body text.
    static func extractFrontmatter(_ lines: inout [String]) -> [String: [String]] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  let t = $0.trimmingCharacters(in: .whitespaces)
                  return t == "---" || t == "..."
              })
        else { return [:] }

        var result: [String: [String]] = [:]
        var listKey: String?
        for raw in lines[1..<end] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- "), let key = listKey {
                let value = unquote(String(line.dropFirst(2)))
                if !value.isEmpty { result[key, default: []].append(value) }
                continue
            }
            listKey = nil
            guard result.count < maxFrontmatterKeys,
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                listKey = key
                result[key] = []
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                result[key] = value.dropFirst().dropLast().split(separator: ",")
                    .map { unquote(String($0)) }.filter { !$0.isEmpty }
            } else {
                result[key] = [unquote(value)]
            }
        }
        lines.removeSubrange(0...end)
        return result
    }

    static func unquote(_ value: String) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, let l = t.last, f == l, f == "\"" || f == "'" {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    // MARK: - Block elements

    static func heading(_ line: String) -> MarkdownNote.Heading? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil } // "#tag" is a tag, not a heading
        let text = sanitizeInline(String(rest))
        return text.isEmpty ? nil : .init(level: hashes, text: text)
    }

    static func task(_ line: String) -> MarkdownNote.Task? {
        guard let marker = line.first, "-*+".contains(marker) else { return nil }
        let rest = line.dropFirst().drop(while: { $0 == " " })
        guard rest.count >= 3, rest.hasPrefix("["),
              rest.dropFirst(2).first == "]" else { return nil }
        let box = rest.dropFirst().first!
        guard box == " " || box == "x" || box == "X" else { return nil }
        let text = sanitizeInline(String(rest.dropFirst(3)))
        return text.isEmpty ? nil : .init(text: text, isDone: box != " ")
    }

    static func stripBlockMarkers(_ line: String) -> String {
        var s = Substring(line)
        while s.hasPrefix(">") { s = s.dropFirst().drop(while: { $0 == " " }) }
        if let first = s.first, "-*+".contains(first), s.dropFirst().first == " " {
            s = s.dropFirst(2)
        }
        return sanitizeInline(String(s))
    }

    // MARK: - Inline

    /// Extracts wiki links and http(s) links. Embeds (`![[...]]`, `![](...)`) are ignored.
    static func links(in line: String) -> [MarkdownNote.Link] {
        var found: [MarkdownNote.Link] = []
        for match in line.matches(of: #/(!?)\[\[([^\]\|#]+)[^\]]*\]\]/#) where match.1.isEmpty {
            let target = match.2.trimmingCharacters(in: .whitespaces)
            if !target.isEmpty { found.append(.wiki(target: target)) }
        }
        for match in line.matches(of: #/(!?)\[[^\]]*\]\(([^)\s]+)\)/#) where match.1.isEmpty {
            if let url = URL(string: String(match.2)),
               let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                found.append(.web(url))
            }
        }
        return found
    }

    /// Converts inline Markdown to plain speakable text: embeds and images are
    /// dropped, links become their label, HTML tags/control characters removed.
    static func sanitizeInline(_ text: String) -> String {
        var s = text
        s.replace(#/!\[\[[^\]]*\]\]/#, with: "")
        s.replace(#/!\[[^\]]*\]\([^)]*\)/#, with: "")
        s.replace(#/\[\[([^\]\|]+)\|([^\]]+)\]\]/#) { String($0.2) }
        s.replace(#/\[\[([^\]#]+)(#[^\]]*)?\]\]/#) { String($0.1) }
        s.replace(#/\[([^\]]*)\]\([^)]*\)/#) { String($0.1) }
        s.replace(#/<[^>]*>/#, with: "")
        for marker in ["**", "__", "==", "~~", "`"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }
        s.unicodeScalars.removeAll { CharacterSet.controlCharacters.contains($0) }
        return collapse(s)
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Removes every `open ... close` span; an unterminated span runs to the end.
    static func removingDelimited(_ text: String, open: String, close: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: open) {
            result += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.range(of: close) else { return result }
            rest = after[end.upperBound...]
        }
        return result + rest
    }
}
