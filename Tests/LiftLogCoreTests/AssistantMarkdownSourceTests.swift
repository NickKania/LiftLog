import XCTest
@testable import LiftLogCore

final class AssistantMarkdownSourceTests: XCTestCase {
    func testOrdinaryAndPartialRepliesKeepTheirOriginalSource() {
        for source in ["## Progress\n\n**Keep going", "```swift\nlet value = 4", "- First\n  - Nested", "[Web](https://example.com)"] {
            XCTAssertEqual(AssistantMarkdownSource.sanitized(source), source)
        }
    }

    func testImagesBecomeAltTextAndUnsafeLinksBecomeLabels() {
        let prepared = AssistantMarkdownSource.sanitized("![Setup](https://example.com/image.png) [Private](file:///private/data)")
        let blocks = AssistantMarkdown.parse(prepared)
        guard case .paragraph(let text) = blocks.first else { return XCTFail("Expected text") }
        XCTAssertEqual(String(text.characters), "Setup Private")
        XCTAssertTrue(text.runs.compactMap(\.link).isEmpty)
    }

    func testRewritingPreservesEmphasisTablesCodeAndLiteralPunctuation() {
        let source = """
        **Progress** and \\*literal\\* ![Setup](https://example.com/image.png)

        | Movement | Reps |
        | --- | --- |
        | Bench | 8 |

        ```text
        ![Code stays literal](https://example.com/code.png)
        ```
        """
        let blocks = AssistantMarkdown.parse(AssistantMarkdownSource.sanitized(source))
        guard case .paragraph(let text) = blocks[0], case .table(_, let rows) = blocks[1],
              case .code(_, let code) = blocks[2] else { return XCTFail("Expected rich blocks") }
        XCTAssertEqual(String(text.characters), "Progress and *literal* Setup")
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(String(rows[0][0].characters), "Bench")
        XCTAssertTrue(code.contains("![Code stays literal]"))
    }
}
