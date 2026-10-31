import Foundation
import Markdown

/// Keeps generated resource URLs out of the renderer without modifying its package.
enum AssistantMarkdownSource {
    static func sanitized(_ source: String) -> String {
        var rewriter = ResourceRewriter()
        let document = rewriter.visit(Document(parsing: source))
        // Preserve streaming syntax and whitespace unless a resource needs rewriting.
        return rewriter.didRewriteResources ? document?.format() ?? "" : source
    }

    private struct ResourceRewriter: MarkupRewriter {
        var didRewriteResources = false

        mutating func visitImage(_ image: Markdown.Image) -> (any Markup)? {
            didRewriteResources = true
            return literal(image.plainText)
        }

        mutating func visitLink(_ link: Markdown.Link) -> (any Markup)? {
            guard let url = link.destination.flatMap(URL.init(string:)),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                didRewriteResources = true
                return literal(link.plainText)
            }
            return defaultVisit(link)
        }

        mutating func visitInlineHTML(_ html: InlineHTML) -> (any Markup)? {
            didRewriteResources = true
            return literal(html.rawHTML)
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) -> (any Markup)? {
            didRewriteResources = true
            return Paragraph(literal(html.rawHTML))
        }

        mutating func visitText(_ text: Markdown.Text) -> (any Markup)? {
            literal(text.string)
        }

        private func literal(_ text: String) -> Markdown.Text {
            // MarkupFormatter prints text verbatim. Escape punctuation so image alt
            // text and originally escaped text cannot become new Markdown resources.
            let escaped = text.unicodeScalars.reduce(into: "") { result, scalar in
                let value = scalar.value
                if (33...47).contains(value) || (58...64).contains(value)
                    || (91...96).contains(value) || (123...126).contains(value) {
                    result.append("\\")
                }
                result.unicodeScalars.append(scalar)
            }
            return Markdown.Text(escaped)
        }
    }
}
