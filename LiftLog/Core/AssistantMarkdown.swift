import Foundation
import Markdown

/// A native rendering tree, shared by complete and still-streaming replies.
/// CommonMark handles structure and escaping; no model-authored HTML is executed.
enum AssistantMarkdown {
    indirect enum Block: Equatable {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case list([ListItem])
        case quote([Block])
        case code(language: String?, text: String)
        case table(header: [AttributedString], rows: [[AttributedString]])
        case divider
    }

    struct ListItem: Equatable {
        let marker: String
        let blocks: [Block]
    }

    static func parse(_ source: String) -> [Block] {
        Document(parsing: source).children.compactMap(block)
    }

    private static func block(_ node: any Markup) -> Block? {
        switch node {
        case let paragraph as Paragraph:
            return .paragraph(inline(paragraph))
        case let heading as Heading:
            return .heading(level: heading.level, text: inline(heading))
        case let list as UnorderedList:
            return .list(list.listItems.map { item in
                ListItem(marker: item.checkbox.map { $0 == .checked ? "☑" : "☐" } ?? "•",
                    blocks: item.children.compactMap(block))
            })
        case let list as OrderedList:
            return .list(list.listItems.enumerated().map { index, item in
                ListItem(marker: "\(list.startIndex + UInt(index)).", blocks: item.children.compactMap(block))
            })
        case let quote as BlockQuote:
            return .quote(quote.children.compactMap(block))
        case let code as CodeBlock:
            return .code(language: code.language, text: code.code)
        case let table as Table:
            return .table(header: table.head.cells.map(inline), rows: table.body.rows.map { $0.cells.map(inline) })
        case is ThematicBreak:
            return .divider
        case let html as HTMLBlock:
            return .paragraph(AttributedString(html.rawHTML))
        default:
            return .paragraph(inline(node))
        }
    }

    private static func inline(_ node: any Markup) -> AttributedString {
        switch node {
        case let text as Markdown.Text: return AttributedString(text.string)
        case is SoftBreak: return AttributedString(" ")
        case is LineBreak: return AttributedString("\n")
        case let code as InlineCode:
            var text = AttributedString(code.code)
            text.inlinePresentationIntent = .code
            return text
        case let html as InlineHTML: return AttributedString(html.rawHTML)
        default:
            var text = node.children.reduce(into: AttributedString()) { $0.append(inline($1)) }
            let intent: InlinePresentationIntent
            switch node {
            case is Strong: intent = .stronglyEmphasized
            case is Emphasis: intent = .emphasized
            case is Strikethrough: intent = .strikethrough
            default: intent = []
            }
            if !intent.isEmpty {
                for run in text.runs {
                    text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
                }
            }
            if let link = node as? Markdown.Link, let destination = link.destination,
               let url = URL(string: destination), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                text.link = url
            }
            // Images display their alt text without loading remote resources.
            return text
        }
    }
}
