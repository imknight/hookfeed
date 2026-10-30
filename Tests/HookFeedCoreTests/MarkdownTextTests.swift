import XCTest
@testable import HookFeedCore

final class MarkdownTextTests: XCTestCase {
    func testPlainTitleStripsHeadingEmphasisCodeAndLinks() {
        XCTAssertEqual(MarkdownText.plainTitle("## Verdict: **ACCEPT for the personal build.** I found no Must blockers."),
                       "Verdict: ACCEPT for the personal build. I found no Must blockers.")
        XCTAssertEqual(MarkdownText.plainTitle("`make test` failed"), "make test failed")
        XCTAssertEqual(MarkdownText.plainTitle("See [the PR](https://example.com/1)"), "See the PR")
        XCTAssertEqual(MarkdownText.plainTitle("\n\n# Title\nmore"), "Title")
    }

    func testPlainTitleSkipsMarkerOnlyLines() {
        XCTAssertEqual(MarkdownText.plainTitle("---\n## Actual title"), "Actual title")
        XCTAssertEqual(MarkdownText.plainTitle("**\n___\n> \n`ready`"), "ready")
        XCTAssertEqual(MarkdownText.plainTitle("~~~\nA real title"), "A real title")
    }

    func testTildeFencesAndIndentedCloseStayVerbatim() {
        XCTAssertEqual(MarkdownText.blocks("~~~sh\necho **literal**\n  ~~~\nafter"), [.code("echo **literal**"), .paragraph("after")])
        XCTAssertEqual(MarkdownText.blocks("```sh\necho one\n    ```\nafter"), [.code("echo one"), .paragraph("after")])
        XCTAssertEqual(MarkdownText.blocks("````\n```\n~~~\n````"), [.code("```\n~~~")])
    }

    func testTableEdgesPreserveLonePipeAndRecognizeUnprefixedSeparator() {
        XCTAssertEqual(MarkdownText.blocks("|"), [.paragraph("|")])
        XCTAssertEqual(MarkdownText.blocks("| A | B |\n--- | :---:\n| a | b |"), [.code("| A | B |\n| a | b |")])
        XCTAssertEqual(MarkdownText.blocks("A | B\n--- | ---\na | b"), [.code("A | B\na | b")])
        XCTAssertEqual(MarkdownText.blocks("| --- is content | b |"), [.code("| --- is content | b |")])
    }

    func testPlainTitleLeavesOrdinaryTextAlone() {
        XCTAssertEqual(MarkdownText.plainTitle("2 * 3 = 6"), "2 * 3 = 6")
        XCTAssertEqual(MarkdownText.plainTitle("inbox_rules table ready"), "inbox_rules table ready")
        XCTAssertEqual(MarkdownText.plainTitle("Résumé 🐱 项目"), "Résumé 🐱 项目")
    }

    func testPlainTitleNeverEmpty() {
        XCTAssertEqual(MarkdownText.plainTitle("###"), "###")
        XCTAssertEqual(MarkdownText.plainTitle("****"), "****")
    }

    func testBlocksSplitHeadingsParagraphsCodeAndTables() {
        let body = "## Verdict\n\nLine one\nline `two`\n\n| Check | Result |\n|---|---|\n| a | b |\n\n```sh\nswift test\n```"
        XCTAssertEqual(MarkdownText.blocks(body), [
            .heading(level: 2, text: "Verdict"),
            .paragraph("Line one\nline `two`"),
            .code("| Check | Result |\n| a | b |"),
            .code("swift test"),
        ])
    }

    func testUnterminatedFenceRunsToEnd() {
        XCTAssertEqual(MarkdownText.blocks("```\nlet x = 1\n\nlet y = 2"), [.code("let x = 1\n\nlet y = 2")])
    }

    func testOmittingTitleDropsDuplicateLeadingBlockOnly() {
        let body = "## Verdict: **ACCEPT**\n\nDetails"
        XCTAssertEqual(MarkdownText.blocks(body, omittingTitle: "## Verdict: **ACCEPT**"), [.paragraph("Details")])
        XCTAssertEqual(MarkdownText.blocks(body, omittingTitle: "Something else").count, 2)
    }

    func testLargeTableBodyParsesAsSingleCodeBlock() {
        let rows = (0..<600).map { "| row \($0) | ok |" }.joined(separator: "\n")
        let blocks = MarkdownText.blocks("| A | B |\n|---|---|\n" + rows)
        XCTAssertEqual(blocks.count, 1)
        guard case .code(let text) = blocks[0] else { return XCTFail("expected code") }
        XCTAssertTrue(text.hasSuffix("| row 599 | ok |"))
    }

    func testRunBodiesStayVerbatim() {
        let body = "Exit code: 1\nCommand: 'echo' 'it'\\''s' '**/*.swift' 'a*b'"
        let run = Message(id: "r", seq: 1, title: "echo failed (exit 1)", body: body, source: "run")
        XCTAssertEqual(run.bodyBlocks, [.code(body)])
        let agent = Message(id: "a", seq: 2, title: "## Done", body: "## Done\n\nAll **good**", source: "claude-code")
        XCTAssertEqual(agent.bodyBlocks, [.paragraph("All **good**")])
        XCTAssertEqual(Message(id: "e", seq: 3, title: "t", body: nil).bodyBlocks, [])
    }

    func testOnlyWebLinksAreAllowed() {
        XCTAssertTrue(MarkdownText.allowsLink(URL(string: "https://example.com/pr/1")!))
        XCTAssertTrue(MarkdownText.allowsLink(URL(string: "HTTP://example.com")!))
        XCTAssertFalse(MarkdownText.allowsLink(URL(string: "file:///Applications/Calculator.app")!))
        XCTAssertFalse(MarkdownText.allowsLink(URL(string: "x-apple.systempreferences:com.apple.preference.security")!))
        XCTAssertFalse(MarkdownText.allowsLink(URL(string: "javascript:alert(1)")!))
    }
}
