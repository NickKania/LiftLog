import Foundation
import Observation

/// A chat owns its live tools and task so switching the displayed chat never redirects output.
@Observable @MainActor
final class WorkoutAssistantChat: Identifiable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [WorkoutAssistantMessage]
    var selectedModel: String
    var isWorking = false
    var errorMessage: String?
    var isGeneratingTitle = false
    var titleError: String?
    @ObservationIgnored var history: [[String: Any]] = []
    @ObservationIgnored let tools: WorkoutAgentTools
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var activeProposalIDs: [UUID] = []
    @ObservationIgnored var titleTask: Task<Void, Never>?
    @ObservationIgnored var titleGeneration = UUID()
    @ObservationIgnored var hasCustomTitle = false
    @ObservationIgnored var hasGeneratedTitle = false

    init(store: WorkoutStore, selectedModel: String) {
        id = UUID()
        title = "New chat"
        createdAt = Date()
        updatedAt = createdAt
        messages = []
        self.selectedModel = selectedModel
        tools = WorkoutAgentTools(store: store)
    }

    init(record: AssistantChatRecord, store: WorkoutStore) {
        id = record.id
        title = record.title
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        messages = record.messages
        selectedModel = record.selectedModel
        errorMessage = record.errorMessage
        titleError = record.titleError
        hasCustomTitle = record.hasCustomTitle
        hasGeneratedTitle = record.hasGeneratedTitle
        history = (try? JSONSerialization.jsonObject(with: record.history)) as? [[String: Any]] ?? []
        tools = WorkoutAgentTools(store: store)
        var invalidated = false
        for index in messages.indices {
            if messages[index].isPartial {
                if messages[index].text.isEmpty { messages[index].text = "Response interrupted when the app closed." }
            }
            // Proposals rely on a live store revision and must be reviewed freshly after relaunch.
            if messages[index].proposal?.status == .pending {
                messages[index].proposal?.status = .stale
                invalidated = true
            }
        }
        if record.wasWorking { errorMessage = "This response was interrupted when the app closed. Its partial reply was saved; send another message to continue." }
        if invalidated {
            history.append(["role": "developer", "content": "The app restarted. All previously pending workout proposals are now stale and cannot be applied. Read fresh workout data and prepare new proposals if requested."])
        }
    }

    func record() throws -> AssistantChatRecord {
        AssistantChatRecord(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                            // Health turns remain visible while the app runs, but never enter backups or archives.
                            messages: messages.filter { !$0.containsEphemeralHealthData }, selectedModel: selectedModel,
                            history: try JSONSerialization.data(withJSONObject: history),
                            wasWorking: isWorking && messages.last(where: { $0.role == .user })?.containsEphemeralHealthData != true,
                            errorMessage: errorMessage, titleError: titleError,
                            hasCustomTitle: hasCustomTitle, hasGeneratedTitle: hasGeneratedTitle)
    }
}

struct AssistantChatRecord: Codable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messages: [WorkoutAssistantMessage]
    let selectedModel: String
    /// Canonical response items, reasoning and function results are retained without reinterpreting them.
    let history: Data
    let wasWorking: Bool
    let errorMessage: String?
    let titleError: String?
    let hasCustomTitle: Bool
    let hasGeneratedTitle: Bool
}

struct AssistantChatAccountRecord: Codable {
    let chats: [AssistantChatRecord]
    let selectedChatID: UUID?
}

struct AssistantChatArchive: Codable {
    var version = 1
    var accounts: [String: AssistantChatAccountRecord] = [:]
    var lastAccount: String?

    static func load(from url: URL) throws -> Self {
        let archive = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw ChatGPTInferenceError("This saved-chat format is not supported by this app.") }
        for account in archive.accounts.values {
            let ids = account.chats.map(\.id)
            guard Set(ids).count == ids.count else { throw ChatGPTInferenceError("Saved chats contain duplicate identifiers.") }
            for chat in account.chats {
                guard !chat.title.isEmpty,
                      (try JSONSerialization.jsonObject(with: chat.history)) is [[String: Any]],
                      Set(chat.messages.map(\.id)).count == chat.messages.count else {
                    throw ChatGPTInferenceError("A saved chat contains invalid conversation data.")
                }
            }
        }
        return archive
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
