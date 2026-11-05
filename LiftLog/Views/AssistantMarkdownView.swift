import EnrichedMarkdown
import SwiftUI

enum AssistantMarkdownConfiguration {
    // Match the original renderer: bare URLs remain text. Explicit links have
    // already passed the app's scheme policy in AssistantMarkdownSource.
    static let parsingOptions = MarkdownParsingOptions(permissiveAutolinks: false)
}

/// Shared by streamed/completed assistant replies and ephemeral workout insights.
struct AssistantMarkdownView: View {
    private let text: String

    init(text: String) {
        self.text = AssistantMarkdownSource.sanitized(text)
    }

    @ScaledMetric(relativeTo: .body) private var paragraphLineHeight = 26
    @ScaledMetric(relativeTo: .subheadline) private var tableLineHeight = 22

    var body: some View {
        EnrichedMarkdownText(text, options: AssistantMarkdownConfiguration.parsingOptions)
            .markdownTheme {
                Heading(1).font(.title2).bold()
                Heading(2).font(.title3).bold()
                Heading(3).font(.headline)
                Heading(4).font(.subheadline).bold()
                Heading(5).font(.footnote).bold()
                Heading(6).font(.caption).bold()
                Paragraph().font(.body).lineHeight(paragraphLineHeight).marginBottom(14)
                Table().font(.subheadline).headerFont(.subheadline).lineHeight(tableLineHeight)
                Blockquote()
                    .foregroundStyle(.secondary)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .lineHeight(paragraphLineHeight)
                CodeBlock().font(.system(.footnote, design: .monospaced))
                Link().foregroundStyle(.blue)
            }
            .markdownCodeBlockLayout(.scrollable)
            .markdownTextSelection(.enabled)
            .tint(.blue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("assistantMarkdownMessage")
    }
}
