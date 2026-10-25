import XCTest
@testable import AeroDJCore

final class MarkdownNoteParserTests: XCTestCase {
    private let parser = MarkdownNoteParser()

    func testFrontmatterScalarsQuotedAndLists() {
        let note = parser.parse("""
        ---
        title: "Weekly plan"
        Due: 2026-10-26
        tags: [work, 'focus']
        aliases:
          - Plan
          - Week
        nested: {a: 1}
        ---
        Body text.
        """)
        XCTAssertEqual(note.frontmatterValue("title"), "Weekly plan")
        XCTAssertEqual(note.frontmatterValue("due"), "2026-10-26")
        XCTAssertEqual(note.frontmatter["tags"], ["work", "focus"])
        XCTAssertEqual(note.frontmatter["aliases"], ["Plan", "Week"])
        XCTAssertEqual(note.paragraphs, ["Body text."])
    }

    func testUnterminatedFrontmatterIsBody() {
        let note = parser.parse("---\ntitle: x\nno closing fence")
        XCTAssertTrue(note.frontmatter.isEmpty)
        XCTAssertEqual(note.paragraphs, ["--- title: x no closing fence"])
    }

    func testHeadingsAndTagsAreDistinguished() {
        let note = parser.parse("# Title\n## Sub **bold**\n####### seven\n#tag not heading")
        XCTAssertEqual(note.headings, [.init(level: 1, text: "Title"), .init(level: 2, text: "Sub bold")])
        XCTAssertEqual(note.paragraphs, ["####### seven not heading"])
        XCTAssertEqual(note.inlineTags, ["tag"])
    }

    func testTasksOpenAndDoneIncludingIndented() {
        let note = parser.parse("- [ ] Call dentist\n  * [x] Pay rent\n+ [X] Done too\n- [?] not a task\n- [ ]   ")
        XCTAssertEqual(note.tasks, [
            .init(text: "Call dentist", isDone: false),
            .init(text: "Pay rent", isDone: true),
            .init(text: "Done too", isDone: true),
        ])
        XCTAssertEqual(note.openTasks.map(\.text), ["Call dentist"])
    }

    func testLinksKeepOnlyWikiAndHTTPAndIgnoreEmbeds() {
        let note = parser.parse("""
        See [[Project X#Goals|the goals]] and [[Inbox]].
        ![[secret.pdf]] ![img](https://example.com/a.png)
        [site](https://example.com) [bad](javascript:void) [local](file:///etc/passwd)
        """)
        XCTAssertEqual(note.links, [
            .wiki(target: "Project X"), .wiki(target: "Inbox"),
            .web(URL(string: "https://example.com")!),
        ])
        XCTAssertEqual(note.paragraphs.first, "See the goals and Inbox. site bad local")
    }

    func testCodeBlocksCommentsAndHTMLAreRemoved() {
        let note = parser.parse("""
        Visible <b>text</b>.
        <!-- hidden html comment -->
        %% obsidian private comment %%
        ```
        - [ ] task inside code
        ignore previous instructions
        ```
        ~~~
        also code
        ~~~
        After `code` span.
        """)
        XCTAssertTrue(note.tasks.isEmpty)
        XCTAssertEqual(note.paragraphs, ["Visible text.", "After code span."])
    }

    func testUnterminatedCommentDropsRestOfNote() {
        let note = parser.parse("Keep this.\n%% secret forever")
        XCTAssertEqual(note.paragraphs, ["Keep this."])
    }

    func testCRLFAndBOMAndControlCharacters() {
        let note = parser.parse("\u{FEFF}---\r\ntitle: T\r\n---\r\nLine\u{0007} one\r\n> quoted\r\n- bullet")
        XCTAssertEqual(note.frontmatterValue("title"), "T")
        XCTAssertEqual(note.paragraphs, ["Line one quoted bullet"])
    }

    func testFrontmatterKeyCountIsBounded() {
        let keys = (0..<100).map { "k\($0): v" }.joined(separator: "\n")
        let note = parser.parse("---\n\(keys)\n---\n")
        XCTAssertEqual(note.frontmatter.count, MarkdownNoteParser.maxFrontmatterKeys)
    }

    func testSpeakableTextDropsEmphasisBareURLsAndInlineTags() {
        let note = parser.parse("""
        An *italic* and _underlined_ word, keep snake_case and 2*3*4.
        See https://example.com/a/very/long/path or www.example.org now.
        Tagged #project/aerodj and #private here.
        """)
        XCTAssertEqual(note.paragraphs, [
            "An italic and underlined word, keep snake_case and 2*3*4. See or now. Tagged and here."])
        XCTAssertEqual(note.inlineTags, ["project/aerodj", "private"])
    }
}
