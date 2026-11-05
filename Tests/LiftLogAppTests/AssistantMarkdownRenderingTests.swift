import EnrichedMarkdown
import UIKit
import XCTest
@testable import LiftLog

final class AssistantMarkdownRenderingTests: XCTestCase {
    func testGeneratedImagesStayTextWithoutResourceAttachments() {
        let rendered = render("![Bench setup](https://example.com/tracking.png)\n\n![Local](file:///private/image.png)")
        XCTAssertTrue(rendered.string.contains("Bench setup"))
        XCTAssertTrue(rendered.string.contains("Local"))
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            XCTAssertNil(value, "Generated images must not create loading attachments")
        }
    }

    func testOnlyWebAndEmailLinksBecomeTappable() {
        let rendered = render("[Web](https://example.com) [Email](mailto:coach@example.com) [App](liftlog://workout) [File](file:///private/data) [Script](javascript:alert)")
        var urls: [String] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { urls.append(url.absoluteString) }
        }
        XCTAssertEqual(urls, ["https://example.com", "mailto:coach@example.com"])
        for text in ["App", "File", "Script"] { XCTAssertTrue(rendered.string.contains(text)) }
    }

    func testBareURLsStayTextWhileExplicitLinksKeepTheirSchemePolicy() {
        let rendered = render("ftp://example.com/file https://example.com/page www.example.com coach@example.com <file:///private/data> [Web](https://example.com)")
        var urls: [String] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { urls.append(url.absoluteString) }
        }
        XCTAssertEqual(urls, ["https://example.com"])
        XCTAssertTrue(rendered.string.contains("ftp://example.com/file"))
        XCTAssertTrue(rendered.string.contains("https://example.com/page"))
    }

    func testReferenceAndNestedImagesCannotReachTheRenderer() {
        let source = """
        | Movement | Setup |
        | --- | --- |
        | Bench | ![Setup][image] |

        [![Nested](https://example.com/nested.png)](file:///private/data)
        ![\\![Hidden](https://example.com/hidden.png)](https://example.com/outer.png)
        \\![Literal](https://example.com/literal.png)

        [image]: https://example.com/table.png
        """
        let prepared = AssistantMarkdownSource.sanitized(source)
        let root = Parser.shared.parseMarkdown(prepared, options: AssistantMarkdownConfiguration.parsingOptions)
        func check(_ node: MarkdownASTNode) {
            XCTAssertNotEqual(node.type, .image)
            if node.type == .link {
                let scheme = node.attribute("url").flatMap(URL.init(string:))?.scheme?.lowercased()
                XCTAssertTrue(["http", "https", "mailto"].contains(scheme ?? ""))
            }
            node.children.forEach(check)
        }
        check(root)
    }

    func testStreamedMarkdownCanFinishWithoutLeavingLiteralSyntax() {
        let partial = render("## Progress\n\n**Keep going")
        XCTAssertTrue(partial.string.contains("Keep going"))
        let completed = render("## Progress\n\n**Keep going**\n\n- Add one rep\n  - Keep the load steady")
        XCTAssertTrue(completed.string.contains("Progress"))
        XCTAssertTrue(completed.string.contains("Keep the load steady"))
        XCTAssertFalse(completed.string.contains("**"))
        XCTAssertFalse(completed.string.contains("##"))
        let range = (completed.string as NSString).range(of: "Keep going")
        let font = completed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    private func render(_ source: String) -> NSAttributedString {
        MarkdownRenderer.render(AssistantMarkdownSource.sanitized(source), config: .init(),
                                options: AssistantMarkdownConfiguration.parsingOptions)
    }
}
