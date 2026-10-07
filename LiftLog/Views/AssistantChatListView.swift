import SwiftUI

struct AssistantChatListView: View {
    @Environment(WorkoutAssistant.self) private var assistant
    @Environment(ChatGPTAccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    let onSelect: (UUID) -> Void
    let onCreate: () -> Void
    @State private var renamingChatID: UUID?
    @State private var editedTitle = ""
    @State private var deletingChat: WorkoutAssistantChat?

    var body: some View {
        NavigationStack {
            List {
                if assistant.chats.isEmpty {
                    ContentUnavailableView("No saved chats", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Your conversations appear here for later reference."))
                        .listRowBackground(Color.clear)
                }
                if let error = assistant.storageErrorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                ForEach(assistant.chats.sorted { $0.updatedAt > $1.updatedAt }) { chat in
                    HStack(spacing: 12) {
                        Button { onSelect(chat.id) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(chat.title).font(.headline).foregroundStyle(.primary)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    if chat.isWorking {
                                        Text("Working…").foregroundStyle(.secondary)
                                    } else if chat.isGeneratingTitle {
                                        Text("Naming chat…").foregroundStyle(.secondary)
                                    } else {
                                        Text(chat.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                            .foregroundStyle(.secondary)
                                    }
                                    if let error = chat.titleError {
                                        Text(error).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if chat.isWorking || chat.isGeneratingTitle {
                                    ProgressView()
                                        .accessibilityLabel(chat.isWorking ? "Response in progress" : "Generating chat title")
                                        .accessibilityIdentifier("assistantChatWorking.\(chat.id.uuidString)")
                                } else if assistant.selectedChatID == chat.id {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                        .accessibilityLabel("Current chat")
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("assistantChat.\(chat.id.uuidString)")
                        Button {
                            editedTitle = chat.title
                            renamingChatID = chat.id
                        } label: {
                            Image(systemName: "pencil").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Rename \(chat.title)")
                        .accessibilityIdentifier("assistantRenameChat.\(chat.id.uuidString)")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { deletingChat = chat } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("assistantDeleteChat.\(chat.id.uuidString)")
                    }
                    .contextMenu {
                        Button("Delete chat", systemImage: "trash", role: .destructive) {
                            deletingChat = chat
                        }
                    }
                }
            }
            .accessibilityIdentifier("assistantChatList")
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("assistantChatListDoneButton")
                }
                if accounts.canUsePlan {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("New chat", systemImage: "square.and.pencil", action: onCreate)
                            .accessibilityIdentifier("assistantChatListNewButton")
                    }
                }
            }
            .alert("Rename chat", isPresented: Binding(
                get: { renamingChatID != nil },
                set: { if !$0 { renamingChatID = nil } }
            )) {
                TextField("Chat title", text: $editedTitle)
                    .accessibilityIdentifier("assistantChatTitleField")
                    .onChange(of: editedTitle) { _, title in
                        if title.count > 120 { editedTitle = String(title.prefix(120)) }
                    }
                Button("Save") {
                    if let id = renamingChatID { assistant.renameChat(id, title: editedTitle) }
                    renamingChatID = nil
                }
                .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { renamingChatID = nil }
            } message: {
                Text("Choose a title up to 120 characters.")
            }
            .alert("Delete chat?", isPresented: Binding(
                get: { deletingChat != nil },
                set: { if !$0 { deletingChat = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let chat = deletingChat { assistant.deleteChat(chat.id) }
                    deletingChat = nil
                }
                Button("Cancel", role: .cancel) { deletingChat = nil }
            } message: {
                Text("\"\(deletingChat?.title ?? "This chat")\" and its messages will be permanently deleted from this device. Any response in progress will stop.")
            }
        }
    }
}
