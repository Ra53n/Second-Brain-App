// CloudProviderTests.swift — тесты облачных провайдеров (задача 08), без сети.
//
// Покрытие по критериям приёмки:
//  - DTO кодирование/декодирование по фикстурам реальных ответов (Fixtures/);
//  - SSE-парсер построчно (частичные события, [DONE]);
//  - маппинг ошибок (401/403/... → понятные LLMError через errorMessage(from:));
//  - логика нарезки аудио (границы по длительности);
//  - multipart/form-data сборка.
//
// Фикстуры openai_error_401.json / gemini_error_403.json / deepgram_error_401.json /
// assemblyai_error_401.json сняты живыми запросами без ключа (см. заголовки
// соответствующих *Provider.swift) — это РЕАЛЬНЫЙ формат ошибок этих API,
// не выдуманный.

import XCTest
@testable import SecondBrain

/// Загрузка фикстур из Tests/SecondBrainTests/Fixtures (SPM resource bundle).
enum TestFixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw NSError(domain: "TestFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "фикстура «\(name)» не найдена"])
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

/// Оборачивает массив строк в AsyncSequence<String> — для SSEStream без сети.
struct AsyncLineArray: AsyncSequence {
    typealias Element = String
    let lines: [String]

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: IndexingIterator<[String]>
        mutating func next() async -> String? { iterator.next() }
    }
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: lines.makeIterator())
    }
}

// MARK: - SSEStream

final class SSEStreamTests: XCTestCase {

    func testExtractsDataPayloadsIgnoringOtherLines() async throws {
        let lines = AsyncLineArray(lines: [
            "event: message", // не data-строка — игнорируется
            "data: {\"a\":1}",
            "",
            "data: {\"a\":2}",
            "data: [DONE]"
        ])
        var payloads: [String] = []
        for try await payload in SSEStream.payloads(from: lines) {
            payloads.append(payload)
        }
        XCTAssertEqual(payloads, ["{\"a\":1}", "{\"a\":2}"])
    }

    func testEmptyDataLineIgnored() async throws {
        let lines = AsyncLineArray(lines: ["data:", "data: ", "data: x"])
        var payloads: [String] = []
        for try await payload in SSEStream.payloads(from: lines) {
            payloads.append(payload)
        }
        XCTAssertEqual(payloads, ["x"])
    }

    func testOpenAIFixtureStreamAccumulatesText() async throws {
        let raw = try TestFixtures.string("openai_chat_stream.txt")
        let lines = AsyncLineArray(lines: raw.components(separatedBy: "\n"))

        var text = ""
        for try await payload in SSEStream.payloads(from: lines) {
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data),
                  let delta = chunk.choices.first?.delta.content else { continue }
            text += delta
        }
        XCTAssertEqual(text, "Привет, мир")
    }

    func testGeminiFixtureStreamAccumulatesText() async throws {
        let raw = try TestFixtures.string("gemini_generate_stream.txt")
        let lines = AsyncLineArray(lines: raw.components(separatedBy: "\n"))

        var text = ""
        for try await payload in SSEStream.payloads(from: lines) {
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(GenerateContentResponse.self, from: data),
                  let delta = chunk.candidates?.first?.content?.parts?.first?.text else { continue }
            text += delta
        }
        XCTAssertEqual(text, "Привет, мир!")
    }
}

// MARK: - MultipartFormData

final class MultipartFormDataTests: XCTestCase {

    func testBuildsFieldAndFileWithBoundaries() throws {
        var form = MultipartFormData()
        form.addField(name: "model", value: "whisper-1")
        form.addFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: Data("RIFF-fake".utf8))
        let body = form.finalize()
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(text.contains("--\(form.boundary)"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"model\""))
        XCTAssertTrue(text.contains("whisper-1"))
        XCTAssertTrue(text.contains("filename=\"audio.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(text.contains("RIFF-fake"))
        XCTAssertTrue(text.hasSuffix("--\(form.boundary)--\r\n"))
    }

    func testContentTypeHeaderMatchesBoundary() {
        let form = MultipartFormData()
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=\(form.boundary)")
    }
}

// MARK: - AudioChunker (планирование границ, без реального экспорта)

final class AudioChunkerTests: XCTestCase {

    func testExactMultipleOfChunkDuration() {
        let plan = AudioChunker.planChunks(duration: 60, maxChunkDuration: 20)
        XCTAssertEqual(plan, [
            AudioChunkPlan(start: 0, end: 20),
            AudioChunkPlan(start: 20, end: 40),
            AudioChunkPlan(start: 40, end: 60)
        ])
    }

    func testRemainderProducesShorterLastChunk() {
        let plan = AudioChunker.planChunks(duration: 50, maxChunkDuration: 20)
        XCTAssertEqual(plan, [
            AudioChunkPlan(start: 0, end: 20),
            AudioChunkPlan(start: 20, end: 40),
            AudioChunkPlan(start: 40, end: 50)
        ])
    }

    func testDurationShorterThanLimitGivesSingleChunk() {
        XCTAssertEqual(AudioChunker.planChunks(duration: 5, maxChunkDuration: 20), [AudioChunkPlan(start: 0, end: 5)])
    }

    func testNonPositiveInputsGiveEmptyPlan() {
        XCTAssertEqual(AudioChunker.planChunks(duration: 0, maxChunkDuration: 20), [])
        XCTAssertEqual(AudioChunker.planChunks(duration: -5, maxChunkDuration: 20), [])
        XCTAssertEqual(AudioChunker.planChunks(duration: 60, maxChunkDuration: 0), [])
    }
}

// MARK: - OpenAIProvider

final class OpenAIProviderTests: XCTestCase {

    func testDecodesChatCompletionFixture() throws {
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: TestFixtures.data("openai_chat_success.json"))
        XCTAssertEqual(decoded.choices.first?.message.content, "Привет! Чем могу помочь?")
        XCTAssertEqual(decoded.usage?.prompt_tokens, 12)
        XCTAssertEqual(decoded.usage?.total_tokens, 19)
    }

    func testEncodesRequestBodyWithStreamFlag() throws {
        let body = ChatRequestBody(
            model: "gpt-4o-mini",
            messages: [RequestMessage(ChatMessageDTO(role: .user, content: "привет"))],
            temperature: 0.7, top_p: 1.0, max_tokens: 100, stop: nil, stream: true
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json?["stream"] as? Bool, true)
        let messages = json?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
        XCTAssertNil(json?["stop"]) // nil stop не должен попасть в JSON
    }

    func testDecodesWhisperVerboseFixtureWithSegments() throws {
        let decoded = try JSONDecoder().decode(WhisperVerboseResponse.self, from: TestFixtures.data("openai_whisper_verbose.json"))
        XCTAssertEqual(decoded.language, "russian")
        XCTAssertEqual(decoded.segments?.count, 2)
        XCTAssertEqual(decoded.segments?[0].start, 0.0)
        XCTAssertEqual(decoded.segments?[1].end, 4.32)
    }

    func testDecodesEmbeddingFixtureAndSortsByIndex() throws {
        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: TestFixtures.data("openai_embeddings.json"))
        // Фикстура намеренно хранит индексы не по порядку — сортировка как в embed().
        let vectors = decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
        XCTAssertEqual(vectors, [[0.1, 0.2, 0.3], [0.2, 0.3, 0.4]])
    }

    func testErrorMessageMapsRealAPIErrorBody() throws {
        let message = OpenAIProvider.errorMessage(from: try TestFixtures.data("openai_error_401.json"))
        XCTAssertEqual(message, "You didn't provide an API key. You need to provide your API key in an Authorization header using Bearer auth (i.e. Authorization: Bearer YOUR_KEY), or as the password field (with blank username) if you're accessing the API from your browser and are prompted for a username and password. You can obtain an API key from https://platform.openai.com/account/api-keys.")
    }

    func testErrorMessageReturnsNilForUnrelatedJSON() {
        XCTAssertNil(OpenAIProvider.errorMessage(from: Data("{\"unexpected\":true}".utf8)))
    }

    func testTranscribeThrowsMissingKeyWithoutEnvOrKeychain() async {
        KeyStore.service = "com.local.second-brain.tests.\(UUID().uuidString)"
        let provider = OpenAIProvider()
        do {
            _ = try await provider.send([], settings: ChatSettings(model: "gpt-4o-mini"))
            XCTFail("ожидалась LLMError.missingAPIKey")
        } catch {
            XCTAssertEqual(error as? LLMError, .missingAPIKey(OpenAIProvider.id))
        }
    }
}

// MARK: - GeminiProvider

final class GeminiProviderTests: XCTestCase {

    func testDecodesGenerateContentFixture() throws {
        let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: TestFixtures.data("gemini_generate_success.json"))
        XCTAssertEqual(decoded.candidates?.first?.content?.parts?.first?.text, "Привет! Чем могу помочь?")
        XCTAssertEqual(decoded.usageMetadata?.totalTokenCount, 16)
    }

    func testDecodesBatchEmbedFixture() throws {
        let decoded = try JSONDecoder().decode(BatchEmbedResponse.self, from: TestFixtures.data("gemini_embed_batch.json"))
        XCTAssertEqual(decoded.embeddings.map(\.values), [[0.11, 0.22, 0.33], [0.44, 0.55, 0.66]])
    }

    func testErrorMessageMapsRealAPIErrorBody() throws {
        let message = GeminiProvider.errorMessage(from: try TestFixtures.data("gemini_error_403.json"))
        XCTAssertEqual(message, "Method doesn't allow unregistered callers (callers without established identity). Please use API Key or other form of API consumer identity to call this API.")
    }

    /// Gemini не принимает роль «system» в contents — system-сообщения уходят
    /// в systemInstruction, assistant маппится в «model».
    func testRoleMappingMovesSystemToInstructionAndRenamesAssistant() {
        let provider = GeminiProvider()
        let messages = [
            ChatMessageDTO(role: .system, content: "Ты — ассистент."),
            ChatMessageDTO(role: .user, content: "Привет"),
            ChatMessageDTO(role: .assistant, content: "Привет!")
        ]
        let body = provider.makeGenerateContentBody(messages, settings: ChatSettings(model: "gemini-2.0-flash"))

        XCTAssertEqual(body.systemInstruction?.parts?.first?.text, "Ты — ассистент.")
        XCTAssertEqual(body.contents.map(\.role), ["user", "model"])
        XCTAssertEqual(body.contents.map { $0.parts?.first?.text }, ["Привет", "Привет!"])
    }

    func testNoSystemMessagesGivesNilInstruction() {
        let provider = GeminiProvider()
        let body = provider.makeGenerateContentBody(
            [ChatMessageDTO(role: .user, content: "привет")],
            settings: ChatSettings(model: "gemini-2.0-flash")
        )
        XCTAssertNil(body.systemInstruction)
    }

    func testEncodesInlineAudioPart() throws {
        let part = GeneratePart.inline(mimeType: "audio/mpeg", base64: "AAAA")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(part)) as? [String: Any]
        let inlineData = json?["inlineData"] as? [String: Any]
        XCTAssertEqual(inlineData?["mimeType"] as? String, "audio/mpeg")
        XCTAssertEqual(inlineData?["data"] as? String, "AAAA")
    }
}

// MARK: - DeepgramProvider

final class DeepgramProviderTests: XCTestCase {

    func testDecodesTranscriptFixtureAndGroupsSpeakers() throws {
        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: TestFixtures.data("deepgram_transcript.json"))
        let alternative = try XCTUnwrap(decoded.results?.channels.first?.alternatives.first)
        XCTAssertEqual(alternative.transcript, "привет как дела всё хорошо")

        let segments = DeepgramProvider.groupBySpeaker(alternative.words ?? [])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Speaker 0: привет как дела")
        XCTAssertEqual(segments[0].start, 0.08)
        XCTAssertEqual(segments[0].end, 1.1)
        XCTAssertEqual(segments[1].text, "Speaker 1: всё хорошо")
        XCTAssertEqual(segments[1].start, 1.6)
    }

    func testGroupBySpeakerWithoutSpeakerLabelsGivesSingleSegment() {
        let words = [
            DeepgramResponse.Word(word: "раз", start: 0, end: 0.3, speaker: nil),
            DeepgramResponse.Word(word: "два", start: 0.3, end: 0.6, speaker: nil)
        ]
        let segments = DeepgramProvider.groupBySpeaker(words)
        XCTAssertEqual(segments, [TranscriptSegment(text: "раз два", start: 0, end: 0.6)])
    }

    func testGroupBySpeakerEmptyInput() {
        XCTAssertEqual(DeepgramProvider.groupBySpeaker([]), [])
    }

    func testErrorMessageMapsRealAPIErrorBody() throws {
        let message = DeepgramProvider.errorMessage(from: try TestFixtures.data("deepgram_error_401.json"))
        XCTAssertEqual(message, "Invalid credentials.")
    }
}

// MARK: - AssemblyAIProvider

final class AssemblyAIProviderTests: XCTestCase {

    func testDecodesCompletedFixture() throws {
        let decoded = try JSONDecoder().decode(TranscriptResult.self, from: TestFixtures.data("assemblyai_transcript_completed.json"))
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.text, "привет как дела всё хорошо")
        XCTAssertEqual(decoded.words?.count, 5)
    }

    func testDecodesQueuedFixtureWithNullFields() throws {
        let decoded = try JSONDecoder().decode(TranscriptResult.self, from: TestFixtures.data("assemblyai_transcript_queued.json"))
        XCTAssertEqual(decoded.status, .queued)
        XCTAssertNil(decoded.text)
    }

    func testShouldContinuePollingOnlyForNonTerminalStatuses() {
        XCTAssertTrue(AssemblyAIPolling.shouldContinuePolling(.queued))
        XCTAssertTrue(AssemblyAIPolling.shouldContinuePolling(.processing))
        XCTAssertFalse(AssemblyAIPolling.shouldContinuePolling(.completed))
        XCTAssertFalse(AssemblyAIPolling.shouldContinuePolling(.error))
    }

    /// Таймкоды AssemblyAI — в миллисекундах; сегменты должны быть в секундах.
    func testGroupBySpeakerConvertsMillisecondsToSeconds() throws {
        let decoded = try JSONDecoder().decode(TranscriptResult.self, from: TestFixtures.data("assemblyai_transcript_completed.json"))
        let segments = AssemblyAIProvider.groupBySpeaker(decoded.words ?? [])

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Speaker A: привет как дела")
        XCTAssertEqual(segments[0].start, 0.08)
        XCTAssertEqual(segments[0].end, 1.1)
        XCTAssertEqual(segments[1].text, "Speaker B: всё хорошо")
    }

    func testErrorMessageMapsRealAPIErrorBody() throws {
        let message = AssemblyAIProvider.errorMessage(from: try TestFixtures.data("assemblyai_error_401.json"))
        XCTAssertEqual(message, "Authentication error, API token missing/invalid")
    }
}

// MARK: - Регистрация в ProviderRegistry

@MainActor
final class CloudProvidersRegistrationTests: XCTestCase {

    func testRegisterAllPopulatesFourProviders() {
        let registry = ProviderRegistry()
        CloudProviders.registerAll(in: registry)

        XCTAssertEqual(registry.descriptors.count, 4)
        XCTAssertEqual(registry.descriptor(for: OpenAIProvider.id)?.capabilities, [.chat, .transcription, .embedding])
        XCTAssertEqual(registry.descriptor(for: GeminiProvider.id)?.capabilities, [.chat, .transcription, .embedding])
        XCTAssertEqual(registry.descriptor(for: DeepgramProvider.id)?.capabilities, [.transcription])
        XCTAssertEqual(registry.descriptor(for: AssemblyAIProvider.id)?.capabilities, [.transcription])
        XCTAssertNotNil(registry.chatProvider(for: OpenAIProvider.id))
        XCTAssertNotNil(registry.embeddingProvider(for: GeminiProvider.id))
        XCTAssertNil(registry.chatProvider(for: DeepgramProvider.id))
    }

    func testAllDescriptorsRequireKeyAndHaveDefaultModel() {
        let registry = ProviderRegistry()
        CloudProviders.registerAll(in: registry)

        for descriptor in registry.descriptors {
            XCTAssertTrue(descriptor.requiresKey, "\(descriptor.id) облачный — обязан требовать ключ")
            XCTAssertNotNil(descriptor.defaultModel, "\(descriptor.id) обязан иметь модель по умолчанию")
        }
    }
}
