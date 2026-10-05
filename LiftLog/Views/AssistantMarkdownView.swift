import SwiftUI

struct AssistantMarkdownView: View {
    private let blocks: [AssistantMarkdown.Block]

    init(text: String) { blocks = AssistantMarkdown.parse(text) }

    var body: some View {
        MarkdownBlocksView(blocks: blocks)
            .font(.body)
            .lineSpacing(4)
            .textSelection(.enabled)
            .tint(.blue)
            .accessibilityIdentifier("assistantMarkdownMessage")
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [AssistantMarkdown.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: AssistantMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .list(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.marker).monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        MarkdownBlocksView(blocks: item.blocks)
                    }
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.blue.opacity(0.45)).frame(width: 3)
                MarkdownBlocksView(blocks: blocks).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "Code")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy code", systemImage: "document.on.document")
                            .font(.caption)
                    }.buttonStyle(.borderless)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: text.hasSuffix("\n") ? String(text.dropLast()) : text)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }.padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    tableRow(header, isHeader: true, shaded: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        tableRow(row, isHeader: false, shaded: index.isMultiple(of: 2))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 10))
            }
        case .divider:
            Divider().padding(.vertical, 2)
        }
    }

    private func tableRow(_ cells: [AttributedString], isHeader: Bool, shaded: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                    .frame(minWidth: 100, maxWidth: 240, alignment: .leading)
                    .padding(12)
                    .background(shaded ? Color(.tertiarySystemGroupedBackground) : .clear)
            }
        }
    }
}
