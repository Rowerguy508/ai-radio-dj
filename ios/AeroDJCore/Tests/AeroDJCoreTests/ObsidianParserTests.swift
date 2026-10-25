import XCTest
@testable import AeroDJCore

final class ObsidianParserTests: XCTestCase {
    func testFrontmatterSkipped() {
        let p = ObsidianParser()
        let md = """
        ---
        title: My Note
        tags: [work, project]
        ---
        # Heading
        - [ ] Finish the report
        """
        let items = p.parse(md, fileID: "note1")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Heading")
        XCTAssertEqual(items[0].summary, "- [ ] Finish the report")
        XCTAssertEqual(items[0].provenance, "obsidian://note1#0")
    }

    func testWikilinkSanitized() {
        let p = ObsidianParser()
        let md = "- See [[Project Alpha|the project]] for details"
        let items = p.parse(md, fileID: "n")
        XCTAssertEqual(items[0].summary, "- See the project for details")
    }

    func testMarkdownLinkSanitized() {
        let p = ObsidianParser()
        let md = "- Read [the doc](https://example.com)"
        let items = p.parse(md, fileID: "n")
        XCTAssertEqual(items[0].summary, "- Read the doc")
    }

    func testLinksOnlyLinesSkipped() {
        let p = ObsidianParser()
        let md = "[[Some Other Note]]\n- [x] Done task"
        let items = p.parse(md, fileID: "n")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].summary, "- [x] Done task")
    }

    func testEmptyAndControlChars() {
        let p = ObsidianParser()
        let md = "- Task\u{0000} with control"
        let items = p.parse(md, fileID: "n")
        XCTAssertEqual(items[0].summary, "- Task with control")
    }

    func testNoContentEmpty() {
        let p = ObsidianParser()
        XCTAssertTrue(p.parse("", fileID: "n").isEmpty)
        XCTAssertTrue(p.parse("---\ntitle: x\n---\n", fileID: "n").isEmpty)
    }
}
