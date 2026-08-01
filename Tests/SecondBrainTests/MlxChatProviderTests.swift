// MlxChatProviderTests.swift — ChatProvider поверх mlx_lm.server (задача 85): успешный
// ответ + usage, не-2xx → badStatus с деталью из {"detail": …}, пустые choices →
// emptyResponse, stream отдаёт один .text и одно .usage, beforeSend/afterSend вокруг запроса.

import XCTest
@testable import SecondBrain

final class MlxChatProviderTests: XCTestCase {

    private func httpResponse(_ code: Int, url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testSendReturnsTextAndUsage() async throws {
        let json = #"{"choices":[{"message":{"content":"Привет"}}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#
        let provider = MlxChatProvider(port: 18765, transport: { request in
            (Data(json.utf8), self.httpResponse(200, url: request.url!))
        })
        let result = try await provider.send([ChatMessageDTO(role: .user, content: "привет")],
                                              settings: ChatSettings(model: "mlx"))
        XCTAssertEqual(result.text, "Привет")
        XCTAssertEqual(result.usage, ChatUsage(promptTokens: 5, completionTokens: 2, totalTokens: 7))
    }

    func testBadStatusThrowsWithDetailFromMlxErrorFormat() async {
        let json = #"{"detail":"model not loaded"}"#
        let provider = MlxChatProvider(port: 18765, transport: { request in
            (Data(json.utf8), self.httpResponse(500, url: request.url!))
        })
        do {
            _ = try await provider.send([ChatMessageDTO(role: .user, content: "x")], settings: ChatSettings(model: "mlx"))
            XCTFail("ожидалась ошибка")
        } catch LLMError.badStatus(let code, let message) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message, "model not loaded")
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }

    func testEmptyChoicesThrowsEmptyResponse() async {
        let json = #"{"choices":[]}"#
        let provider = MlxChatProvider(port: 18765, transport: { request in
            (Data(json.utf8), self.httpResponse(200, url: request.url!))
        })
        do {
            _ = try await provider.send([ChatMessageDTO(role: .user, content: "x")], settings: ChatSettings(model: "mlx"))
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(error as? LLMError, .emptyResponse)
        }
    }

    func testStreamYieldsSingleTextThenUsageEvent() async throws {
        let json = #"{"choices":[{"message":{"content":"Ответ"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#
        let provider = MlxChatProvider(port: 18765, transport: { request in
            (Data(json.utf8), self.httpResponse(200, url: request.url!))
        })
        var events: [ChatStreamEvent] = []
        for try await event in provider.stream([ChatMessageDTO(role: .user, content: "x")], settings: ChatSettings(model: "mlx")) {
            events.append(event)
        }
        XCTAssertEqual(events, [.text("Ответ"), .usage(ChatUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2))])
    }

    /// Ollama-стиль ответа: ключ "usage" отсутствует вовсе — не пустой объект, а нет ключа.
    func testResponseWithoutUsageKeyReturnsNilUsage() async throws {
        let json = #"{"choices":[{"message":{"content":"ок"}}]}"#
        let provider = MlxChatProvider(port: 18765, transport: { request in
            (Data(json.utf8), self.httpResponse(200, url: request.url!))
        })
        let result = try await provider.send([ChatMessageDTO(role: .user, content: "x")], settings: ChatSettings(model: "mlx"))
        XCTAssertEqual(result.text, "ок")
        XCTAssertNil(result.usage)
    }

    func testBeforeAndAfterSendHooksFireAroundEachCall() async throws {
        let json = #"{"choices":[{"message":{"content":"ок"}}]}"#
        var before = 0, after = 0
        let provider = MlxChatProvider(port: 18765, transport: { request in
            (Data(json.utf8), self.httpResponse(200, url: request.url!))
        }, beforeSend: { before += 1 }, afterSend: { after += 1 })
        _ = try await provider.send([ChatMessageDTO(role: .user, content: "x")], settings: ChatSettings(model: "mlx"))
        XCTAssertEqual(before, 1)
        XCTAssertEqual(after, 1)
    }
}
