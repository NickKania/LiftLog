import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Uses only SystemLanguageModel, never a cloud model or ChatGPT credentials.
/// Every generation owns a fresh native session: only explicit, successfully
/// completed core context is replayed; Health consent cannot survive a request.
@MainActor
final class AppleFoundationModelsProvider: AppleFoundationModelsProviding {
    var contextTokens: Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.4, macOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        #endif
        return FoundationModelsBudget.contextTokens
    }

    var availability: AppleFoundationModelsAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady): return .modelNotReady
            case .unavailable: return .unavailable
            }
        }
        return .requiresIOS26
        #else
        return .frameworkUnavailable
        #endif
    }

    func models() async throws -> [ChatGPTModel] {
        try Task.checkCancellation()
        guard availability.isAvailable else { throw AppleFoundationModelsError(availability.explanation) }
        return AppleFoundationModelsModel.catalog
    }

    func respond(model: String, input: [[String: Any]], tools: [[String: Any]], instructions: String,
                 onText: (String) -> Void) async throws -> ChatGPTInferenceResponse {
        try Task.checkCancellation()
        guard availability.isAvailable else { throw AppleFoundationModelsError(availability.explanation) }
        guard model == AppleFoundationModelsModel.slug else { throw AppleFoundationModelsError("Select the Apple on-device model before sending.") }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                return try await generate(input: input, tools: tools, instructions: instructions, onText: onText)
            } catch is CancellationError { throw CancellationError() }
            catch let error as AppleFoundationModelsError { throw error }
            catch let error as FoundationModelsToolDispatchError { throw error }
            catch {
                try Task.checkCancellation()
                // Native diagnostics can quote prompts/Health readings. Never expose or archive them.
                if let error = error as? LanguageModelSession.GenerationError {
                    switch error {
                    case .exceededContextWindowSize: throw AppleFoundationModelsError.contextTooLarge
                    case .unsupportedLanguageOrLocale:
                        throw AppleFoundationModelsError("This language is not supported by the on-device model. Check Apple Intelligence language settings.")
                    case .guardrailViolation, .refusal:
                        throw AppleFoundationModelsError("Apple Intelligence could not answer this request. Try rephrasing it.")
                    default: break
                    }
                }
                if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
                    switch error {
                    case .contextSizeExceeded: throw AppleFoundationModelsError.contextTooLarge
                    case .unsupportedLanguageOrLocale:
                        throw AppleFoundationModelsError("This language is not supported by the on-device model. Check Apple Intelligence language settings.")
                    case .guardrailViolation, .refusal:
                        throw AppleFoundationModelsError("Apple Intelligence could not answer this request. Try rephrasing it.")
                    default: break
                    }
                }
                throw AppleFoundationModelsError("The on-device model could not complete this request. Try again or ask for a smaller task.")
            }
        }
        #endif
        throw AppleFoundationModelsError(availability.explanation)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
private extension AppleFoundationModelsProvider {
    func generate(input: [[String: Any]], tools: [[String: Any]], instructions: String,
                  onText: (String) -> Void) async throws -> ChatGPTInferenceResponse {
        let request = try FoundationModelsRequest(input: input, tools: tools, instructions: instructions, contextTokens: contextTokens)
        let nativeInstructions = request.instructions
        if let decisionStage = request.decisionStage, let decisionIR = decisionStage.schema {
            // Select an action first, then generate only that tool's argument schema.
            // Sessions stay independent; tools execute only in the core orchestration
            // loop and proposals still require the separate user review action.
            let decisionSchema = try generationSchema(decisionIR)
            try await checkBudget(instructions: nativeInstructions, stage: decisionStage, schema: decisionSchema)
            let decisionSession = LanguageModelSession(model: .default, instructions: nativeInstructions)
            let decision = try await decisionSession.respond(to: decisionStage.prompt, schema: decisionSchema,
                options: GenerationOptions(temperature: 0, maximumResponseTokens: decisionStage.maximumResponseTokens))
            try Task.checkCancellation()
            let action = try decision.content.value(String.self, forProperty: "action")
            if action != "respond" {
                let arguments: String
                do {
                    let editMode: FoundationModelsEditMode?
                    let preserveSetCounts: Bool
                    if let intentStage = try request.editModeStage(forToolNamed: action), let intentIR = intentStage.schema {
                        let intentSchema = try generationSchema(intentIR)
                        try await checkBudget(instructions: nativeInstructions, stage: intentStage, schema: intentSchema)
                        let intentSession = LanguageModelSession(model: .default, instructions: nativeInstructions)
                        let intent = try await intentSession.respond(to: intentStage.prompt, schema: intentSchema,
                            options: GenerationOptions(temperature: 0, maximumResponseTokens: intentStage.maximumResponseTokens))
                        try Task.checkCancellation()
                        guard intent.content.isComplete,
                              let mode = FoundationModelsEditMode(rawValue: try intent.content.value(String.self, forProperty: "mode")) else {
                            throw FoundationModelsToolDispatchError(toolName: action,
                                message: "The on-device edit intent did not finish. Ask for one smaller exercise change and retry. No tool was executed.")
                        }
                        editMode = mode
                        preserveSetCounts = try intent.content.value(String.self, forProperty: "setCountPolicy") == "keepExistingSetCounts"
                    } else { editMode = nil; preserveSetCounts = false }
                    let stage = try request.argumentStage(forToolNamed: action, editMode: editMode, preserveSetCounts: preserveSetCounts)
                    guard let argumentIR = stage.schema else {
                        throw AppleFoundationModelsError("A workout tool has an invalid argument schema.")
                    }
                    let schema = try generationSchema(argumentIR)
                    try await checkBudget(instructions: nativeInstructions, stage: stage, schema: schema)
                    let session = LanguageModelSession(model: .default, instructions: nativeInstructions)
                    let response = try await session.respond(to: stage.prompt, schema: schema,
                        options: GenerationOptions(temperature: 0, maximumResponseTokens: stage.maximumResponseTokens))
                    try Task.checkCancellation()
                    guard response.content.isComplete else {
                        throw FoundationModelsToolDispatchError(toolName: action,
                            message: "The on-device argument response reached its limit before completion. Propose fewer exercise changes at once or read a smaller page, then retry. No tool was executed.")
                    }
                    let object = try JSONSerialization.jsonObject(with: Data(response.content.jsonString.utf8))
                    arguments = try request.argumentsJSON(restoringIdentifiersIn: object)
                } catch is CancellationError { throw CancellationError() }
                catch let error as FoundationModelsToolDispatchError { throw error }
                catch {
                    try Task.checkCancellation()
                    guard isRecoverablePreparationError(error) else { throw error }
                    // Includes capped/incomplete guided output. No partial arguments
                    // execute; the core exposes a failed-dispatch receipt to the model.
                    throw FoundationModelsToolDispatchError(toolName: action,
                        message: "The on-device tool arguments did not fit or finish. Narrow the read to one exact record or propose fewer exercise changes at once. Read fresh target IDs, use one operation per entry with all its sets, then retry. No tool was executed.")
                }

                let id = UUID().uuidString
                let call = ChatGPTFunctionCall(callID: id, name: action, namespace: "liftlog", arguments: arguments)
                return ChatGPTInferenceResponse(text: "", output: [["type": "function_call", "call_id": id,
                    "name": action, "namespace": "liftlog", "arguments": arguments]], calls: [call])
            }
        }
        guard let answerIR = request.textStage.schema else {
            throw AppleFoundationModelsError("The on-device answer schema is unavailable. Try again.")
        }
        let answerSchema = try generationSchema(answerIR)
        try await checkBudget(instructions: nativeInstructions, stage: request.textStage, schema: answerSchema)
        let session = LanguageModelSession(model: .default, instructions: nativeInstructions)
        let stream = session.streamResponse(to: request.textStage.prompt, schema: answerSchema,
            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: request.textStage.maximumResponseTokens))
        var previous = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            // A partial guided object may not contain its answer field yet. That
            // expected parsing failure is only ignored while streaming, never at EOF.
            if !request.isWorkoutSummary, let answer = try? snapshot.content.value(String.self, forProperty: "answer") {
                let text = request.restoringIdentifiers(in: answer)
                if text.hasPrefix(previous) { onText(String(text.dropFirst(previous.count))) }
                previous = text
            }
        }
        try Task.checkCancellation()
        // collect() returns the cached authoritative response after iteration; it
        // does not start another generation. Success alone does not imply the
        // token cap left a complete object or required completion field.
        let final = try await stream.collect()
        try Task.checkCancellation()
        if request.isWorkoutSummary {
            guard final.rawContent.isComplete else {
                throw AppleFoundationModelsError("The on-device answer did not finish. Ask for a shorter answer or resend the question in smaller parts.")
            }
            let completed = request.restoringIdentifiers(in: try WorkoutSummaryStructuredOutput.markdown(fromJSON: final.content.jsonString))
            return ChatGPTInferenceResponse(text: completed,
                output: [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": completed]]]], calls: [])
        }
        let answer = try? final.content.value(String.self, forProperty: "answer")
        let completion = try? final.content.value(String.self, forProperty: "completion")
        let completed = request.restoringIdentifiers(in: try FoundationModelsTextCompletion.completedAnswer(answer,
            completion: completion, isComplete: final.rawContent.isComplete))
        if completed.hasPrefix(previous) { onText(String(completed.dropFirst(previous.count))) }
        return ChatGPTInferenceResponse(text: completed,
            output: [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": completed]]]], calls: [])
    }

    func checkBudget(instructions: String, stage: FoundationModelsGenerationStage, schema: GenerationSchema? = nil) async throws {
        if #available(iOS 26.4, macOS 26.4, *) {
            let model = SystemLanguageModel.default
            let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
            let promptTokens = try await model.tokenCount(for: stage.prompt)
            let schemaTokens: Int
            if let schema { schemaTokens = try await model.tokenCount(for: schema) }
            else { schemaTokens = 0 }
            try Task.checkCancellation()
            try FoundationModelsBudget.validate(inputTokens: instructionTokens + promptTokens + schemaTokens,
                outputTokens: stage.maximumResponseTokens, contextTokens: model.contextSize)
        } else {
            try stage.validate()
        }
    }

    func isRecoverablePreparationError(_ error: Error) -> Bool {
        if let local = error as? AppleFoundationModelsError { return local.kind == .contextTooLarge }
        if error is DecodingError { return true }
        if #available(iOS 27.0, macOS 27.0, *), error is GeneratedContent.ParsingError { return true }
        if let native = error as? LanguageModelSession.GenerationError {
            switch native {
            case .exceededContextWindowSize, .decodingFailure: return true
            default: return false
            }
        }
        if #available(iOS 27.0, macOS 27.0, *), let native = error as? LanguageModelError {
            if case .contextSizeExceeded = native { return true }
            return false
        }
        let json = error as NSError
        return json.domain == NSCocoaErrorDomain && json.code == 3840
    }

    func generationSchema(_ schema: FoundationModelsSchema) throws -> GenerationSchema {
        try GenerationSchema(root: nativeSchema(schema), dependencies: schema.definitions.map { try nativeSchema($0) })
    }

    /// The only platform-specific part of schema conversion. All JSON semantics,
    /// requiredness, nullability and bounds are represented and tested in Core.
    func nativeSchema(_ schema: FoundationModelsSchema) throws -> DynamicGenerationSchema {
        switch schema.kind {
        case .object(let properties):
            return try DynamicGenerationSchema(name: schema.name, description: schema.description, properties: properties.map { property in
                .init(name: property.name, description: property.schema.generationDescription,
                      schema: try nativeSchema(property.schema), isOptional: property.isOptional)
            })
        case .array(let item, let minimum, let maximum):
            return try DynamicGenerationSchema(arrayOf: nativeSchema(item), minimumElements: minimum, maximumElements: maximum)
        case .integer(let minimum, let maximum):
            var guides: [GenerationGuide<Int>] = []
            if let minimum { guides.append(.minimum(minimum)) }
            if let maximum { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Int.self, guides: guides)
        case .number(let minimum, let maximum):
            var guides: [GenerationGuide<Double>] = []
            if let minimum { guides.append(.minimum(minimum)) }
            if let maximum { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Double.self, guides: guides)
        case .boolean: return DynamicGenerationSchema(type: Bool.self)
        case .anyOf(let options):
            return try DynamicGenerationSchema(name: schema.name, description: schema.description,
                anyOf: options.map { try nativeSchema($0) })
        case .reference(let name): return DynamicGenerationSchema(referenceTo: name)
        case .string(let choices, _, _):
            if let choices { return DynamicGenerationSchema(name: schema.name, description: schema.description, anyOf: choices) }
            // SystemLanguageModel rejects .pattern with UnsupportedGuide on the
            // native model. Length bounds remain in the property's description,
            // the budget IR, and the executor's mandatory argument validation.
            return DynamicGenerationSchema(type: String.self)

        }
    }
}
#endif
