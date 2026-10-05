import Foundation
import XCTest
@testable import LiftLogCore

final class AssistantChatTitleGeneratorTests: XCTestCase {
    private func model(_ slug: String, visibility: String = "list") -> ChatGPTModel {
        ChatGPTModel(slug: slug, displayName: slug, visibility: visibility)
    }

    func testLatestAvailableLunaUsesNumericVersionsAndPrefersAliasOverSnapshot() {
        let catalog = [model("gpt-5.6-luna"), model("gpt-6.9-luna"), model("gpt-6.10-luna"),
                       model("gpt-6.10-luna-2026-10-01"), model("gpt-7-luna", visibility: "hidden"),
                       model("gpt-8-sol"), model("gpt-10-luna-preview")]
        XCTAssertEqual(AssistantChatTitleGenerator.latestLunaModel(in: catalog), "gpt-6.10-luna")
        XCTAssertEqual(AssistantChatTitleGenerator.latestLunaModel(in: [model("gpt-6.1-luna"), model("gpt-6-luna")]), "gpt-6.1-luna")
        XCTAssertEqual(AssistantChatTitleGenerator.latestLunaModel(in: [model("gpt-5.6-luna"), model("gpt-6-luna")]), "gpt-6-luna")
        XCTAssertEqual(AssistantChatTitleGenerator.latestLunaModel(in: [model("gpt-6-luna-2026-09-01"), model("gpt-6-luna-2026-10-01")]), "gpt-6-luna-2026-10-01")
        XCTAssertNil(AssistantChatTitleGenerator.latestLunaModel(in: [model("gpt-6.1-sol")]))
    }

    func testTitleOutputIsOnePlainBoundedLine() {
        XCTAssertEqual(AssistantChatTitleGenerator.sanitize("\n  ### Chat title: **“Weekly training plan”**\nExtra commentary"), "Weekly training plan")
        XCTAssertEqual(AssistantChatTitleGenerator.sanitize("[Bench progress](https://example.com)"), "Bench progress")
        XCTAssertEqual(AssistantChatTitleGenerator.sanitize("<b>Upper body</b>\t progress"), "Upper body progress")
        XCTAssertEqual(AssistantChatTitleGenerator.sanitize("**Bench**\t_training_ progress"), "Bench training progress")
        XCTAssertEqual(AssistantChatTitleGenerator.sanitize(String(repeating: "🏋️", count: 90))?.count, 80)
        XCTAssertNil(AssistantChatTitleGenerator.sanitize("   \n\t"))
        XCTAssertNil(AssistantChatTitleGenerator.sanitize("```"))
    }

    @MainActor
    func testTitleRequestUsesLunaNoToolsAndBoundedVisibleConversation() async throws {
        let transport = TitleInferenceTransport(text: "\"Bench press progress\"")
        let client = ChatGPTInferenceClient(accessToken: { "mock" }, transport: transport)
        let title = try await AssistantChatTitleGenerator.generate(client: client,
            models: [model("gpt-6.1-sol"), model("gpt-6-luna")],
            messages: [WorkoutAssistantMessage(role: .user, text: String(repeating: "u", count: 4_000)),
                       WorkoutAssistantMessage(role: .tool, text: "Private tool snapshot"),
                       WorkoutAssistantMessage(role: .assistant, text: "Partial reply", isPartial: true),
                       WorkoutAssistantMessage(role: .assistant, text: String(repeating: "a", count: 4_000))])
        XCTAssertEqual(title, "Bench press progress")
        let request = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 0)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertLessThan(text.count, 4_100)
        XCTAssertFalse(text.contains("Private tool snapshot"))
        XCTAssertFalse(text.contains("Partial reply"))
    }

    @MainActor
    func testNoAvailableLunaDoesNotRequestAnotherModel() async throws {
        let transport = TitleInferenceTransport(text: "Unused")
        let client = ChatGPTInferenceClient(accessToken: { "mock" }, transport: transport)
        do {
            _ = try await AssistantChatTitleGenerator.generate(client: client,
                models: [model("gpt-6.1-sol")], messages: [])
            XCTFail("No Luna model should leave the local fallback title in place")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Luna"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

private final class TitleInferenceTransport: ChatGPTInferenceTransport {
    var requests: [URLRequest] = []
    let text: String
    init(text: String) { self.text = text }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTFail("Title generation should reuse the already loaded catalog")
        return (Data(), response(request))
    }

    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        requests.append(request)
        let event: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]
        ]]]
        let data = try JSONSerialization.data(withJSONObject: event)
        return ChatGPTHTTPStream(response: response(request), lines: AsyncThrowingStream { continuation in
            continuation.yield("data: " + String(decoding: data, as: UTF8.self))
            continuation.yield("")
            continuation.finish()
        })
    }

    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}
