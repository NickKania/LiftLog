import Foundation

enum AssistantProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case chatGPT, appleFoundationModels

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .appleFoundationModels: "Apple Intelligence"
        }
    }
}

enum AppleFoundationModelsAvailability: Equatable, Sendable {
    case available, requiresIOS26, deviceNotEligible, appleIntelligenceNotEnabled
    case modelNotReady, frameworkUnavailable, unavailable

    var isAvailable: Bool { self == .available }
    var explanation: String {
        switch self {
        case .available: "Ready on this device. Works offline without an account."
        case .requiresIOS26: "Apple Intelligence requires iOS 26 or later."
        case .deviceNotEligible: "This device does not support the Apple Intelligence on-device model."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in Settings to use the on-device model."
        case .modelNotReady: "The on-device model is not ready. Check Apple Intelligence in Settings and allow its download to finish."
        case .frameworkUnavailable: "This build does not include the Foundation Models framework."
        case .unavailable: "The on-device model is currently unavailable. Check Apple Intelligence language and region settings and try again."
        }
    }
}

enum AppleFoundationModelsModel {
    static let slug = "apple-foundation-models"
    static let catalog = [ChatGPTModel(slug: slug, displayName: "Apple on-device model", visibility: "list")]
}

/// Provider-neutral response items are explicit context, never remote continuation IDs.
/// Implementations return tool *requests*. Only WorkoutAssistant executes them, and
/// only the user's separate review action can apply a proposal.
@MainActor
protocol AssistantInferenceClient {
    func models() async throws -> [ChatGPTModel]
    func respond(model: String, input: [[String: Any]], tools: [[String: Any]],
                 instructions: String, onText: (String) -> Void) async throws -> ChatGPTInferenceResponse
}

@MainActor
protocol AppleFoundationModelsProviding: AssistantInferenceClient {
    var availability: AppleFoundationModelsAvailability { get }
    var contextTokens: Int { get }
}

extension AppleFoundationModelsProviding {
    // Synthetic app fixtures and providers without a native window use the fallback.
    var contextTokens: Int { FoundationModelsBudget.contextTokens }
}

extension ChatGPTInferenceClient: AssistantInferenceClient {}

@MainActor
struct UnavailableAppleFoundationModelsProvider: AppleFoundationModelsProviding {
    let availability: AppleFoundationModelsAvailability
    var contextTokens: Int { FoundationModelsBudget.contextTokens }
    nonisolated init(availability: AppleFoundationModelsAvailability = .frameworkUnavailable) { self.availability = availability }
    func models() async throws -> [ChatGPTModel] { throw AppleFoundationModelsError(availability.explanation) }
    func respond(model: String, input: [[String: Any]], tools: [[String: Any]],
                 instructions: String, onText: (String) -> Void) async throws -> ChatGPTInferenceResponse {
        throw AppleFoundationModelsError(availability.explanation)
    }
}

struct AppleFoundationModelsError: LocalizedError {
    enum Kind: Equatable, Sendable { case contextTooLarge, other }
    let kind: Kind
    let errorDescription: String?
    init(_ message: String, kind: Kind = .other) {
        self.kind = kind
        errorDescription = message
    }
    static let contextTooLarge = Self("This request exceeds the on-device model’s context. Select fewer records, ask for a smaller page of history, or start a new chat. You can explicitly choose ChatGPT for larger requests.", kind: .contextTooLarge)
}
