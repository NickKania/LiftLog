import SwiftUI

struct AssistantMessageView: View {
    let message: WorkoutAssistantMessage
    let isWorking: Bool

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 32)
                VStack(alignment: .leading, spacing: 10) {
                    if !message.text.isEmpty {
                        Text(verbatim: message.text)
                            .textSelection(.enabled)
                            .accessibilityLabel("You: \(message.text)")
                    }
                    ForEach(message.references, id: \.key) { reference in
                        AssistantReferenceLabel(reference: reference)
                            .padding(8)
                            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("assistantMessageReference.\(reference.key)")
                    }
                }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(.blue).accessibilityHidden(true)
                    Text(message.isPartial ? (isWorking ? "Assistant · In progress" : "Assistant · Partial response") : "Assistant")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !message.isPartial {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Image(systemName: "document.on.document").foregroundStyle(.secondary)
                                .frame(width: 44, height: 32)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Copy response")
                            .accessibilityIdentifier("assistantCopyResponseButton")
                    }
                }.font(.caption.weight(.semibold))
                AssistantMarkdownView(text: message.text)
            }.assistantCard()
        }
    }
}
