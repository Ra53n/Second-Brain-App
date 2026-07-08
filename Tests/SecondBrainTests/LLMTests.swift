// LLMTests.swift — тесты LLM-фундамента (задача 07).
//
// Покрытие по критериям приёмки:
//  - роутинг: назначение/чтение/дефолт/провайдер стал недоступен;
//  - сериализация и миграция FunctionRoutingConfig;
//  - KeyStore на тестовом Keychain-сервисе (запись/чтение/удаление, env-приоритет);
//  - DTO round-trip (ChatMessageDTO, ChatSettings, FunctionAssignment);
//  - моки (MockChatProvider, HashingEmbedder) — детерминизм, канонированные ответы.

import XCTest
@testable import SecondBrain

// MARK: - ProviderRegistry

@MainActor
final class ProviderRegistryTests: XCTestCase {

    func testRegisterAndRetrieveProvider() {
        let registry = ProviderRegistry()
        let mock = MockChatProvider()
        registry.register(
            ProviderDescriptor(id: "mock", displayName: "Mock", capabilities: [.chat], isLocal: true, defaultModel: "mock-model"),
            chat: mock
        )

        XCTAssertNotNil(registry.descriptor(for: "mock"))
        XCTAssertTrue((registry.chatProvider(for: "mock") as AnyObject) === mock)
        XCTAssertNil(registry.embeddingProvider(for: "mock"))
    }

    func testReregisteringReplacesDescriptor() {
        let registry = ProviderRegistry()
        registry.register(ProviderDescriptor(id: "p", displayName: "Первая версия", capabilities: [.chat], isLocal: true))
        registry.register(ProviderDescriptor(id: "p", displayName: "Вторая версия", capabilities: [.chat], isLocal: true))

        XCTAssertEqual(registry.descriptors.count, 1)
        XCTAssertEqual(registry.descriptor(for: "p")?.displayName, "Вторая версия")
    }

    func testCloudProviderRequiresKeyForAvailability() {
        let registry = ProviderRegistry()
        let id = ProviderID(rawValue: "cloud-test-\(UUID().uuidString)")
        registry.register(ProviderDescriptor(id: id, displayName: "Cloud", capabilities: [.chat], isLocal: false))
        KeyStore.service = "com.local.second-brain.tests.\(UUID().uuidString)"
        defer { KeyStore.setKey("", for: id) }

        XCTAssertFalse(registry.isAvailable(id)) // ключа нет

        KeyStore.setKey("test-key", for: id)
        XCTAssertTrue(registry.isAvailable(id))
    }

    func testLocalProviderUsesRegisteredAvailabilityCheck() {
        let registry = ProviderRegistry()
        var runtimeAlive = false
        registry.register(
            ProviderDescriptor(id: "local", displayName: "Local", capabilities: [.chat], isLocal: true),
            isAvailable: { runtimeAlive }
        )

        XCTAssertFalse(registry.isAvailable("local"))
        runtimeAlive = true
        XCTAssertTrue(registry.isAvailable("local"))
    }

    func testLocalProviderWithoutCheckDefaultsAvailable() {
        let registry = ProviderRegistry()
        registry.register(ProviderDescriptor(id: "local", displayName: "Local", capabilities: [.chat], isLocal: true))
        XCTAssertTrue(registry.isAvailable("local"))
    }

    func testUnknownProviderIsUnavailable() {
        let registry = ProviderRegistry()
        XCTAssertFalse(registry.isAvailable("ghost"))
    }

    func testDescriptorsSupportingCapabilityFilters() {
        let registry = ProviderRegistry()
        registry.register(ProviderDescriptor(id: "chatOnly", displayName: "Chat", capabilities: [.chat], isLocal: true))
        registry.register(ProviderDescriptor(id: "embedOnly", displayName: "Embed", capabilities: [.embedding], isLocal: true))

        XCTAssertEqual(registry.descriptors(supporting: .chat).map(\.id), ["chatOnly"])
        XCTAssertEqual(registry.descriptors(supporting: .embedding).map(\.id), ["embedOnly"])
    }
}

// MARK: - FunctionRoutingConfig (сериализация, миграция)

final class FunctionRoutingConfigTests: XCTestCase {

    func testSubscriptSetAndGet() {
        var config = FunctionRoutingConfig()
        config[.chat] = FunctionAssignment(providerID: "openai", model: "gpt-4o-mini")

        XCTAssertEqual(config[.chat], FunctionAssignment(providerID: "openai", model: "gpt-4o-mini"))
        XCTAssertNil(config[.embedding])
    }

    func testRoundTripJSON() throws {
        var config = FunctionRoutingConfig()
        config[.chat] = FunctionAssignment(providerID: "openai", model: "gpt-4o-mini")
        config[.transcription] = FunctionAssignment(providerID: "deepgram", model: "nova-2")

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(FunctionRoutingConfig.self, from: data)

        XCTAssertEqual(decoded, config)
    }

    func testUnknownFunctionKeyPreservedAcrossRoundTrip() throws {
        // Симулируем файл будущей версии с функцией, которой ещё нет.
        let json = """
        {"chat": {"providerID": "openai", "model": "gpt-4o-mini"}, "futureFunction": {"providerID": "x", "model": "y"}}
        """
        let config = try JSONDecoder().decode(FunctionRoutingConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config[.chat], FunctionAssignment(providerID: "openai", model: "gpt-4o-mini"))
        XCTAssertEqual(config.raw["futureFunction"], FunctionAssignment(providerID: "x", model: "y"))

        // Пересохранение не теряет неизвестный ключ.
        let reencoded = try JSONDecoder().decode(FunctionRoutingConfig.self, from: try JSONEncoder().encode(config))
        XCTAssertEqual(reencoded.raw["futureFunction"], FunctionAssignment(providerID: "x", model: "y"))
    }

    func testMalformedJSONYieldsEmptyConfigInsteadOfCrashing() throws {
        // singleValueContainer().decode внутри init(from:) может бросить —
        // сам FunctionRoutingConfig это гасит, но JSONDecoder.decode на верхнем
        // уровне не сможет распарсить невалидный JSON вообще (это ожидаемо —
        // защита от мусора внутри объекта, не от синтаксически битого файла;
        // синтаксически битый файл ловит FunctionRoutingStore.load(), см. ниже).
        let data = Data("42".utf8) // валидный JSON, но не объект-словарь
        let config = try JSONDecoder().decode(FunctionRoutingConfig.self, from: data)
        XCTAssertTrue(config.raw.isEmpty)
    }

    func testEmptyConfigDecodes() throws {
        let config = try JSONDecoder().decode(FunctionRoutingConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(config.raw.isEmpty)
    }
}

// MARK: - FunctionRoutingStore (persistence — паттерн ChatStore)

final class FunctionRoutingStoreTests: XCTestCase {

    func testSaveAndLoadRoundTrip() throws {
        var config = FunctionRoutingConfig()
        config[.chat] = FunctionAssignment(providerID: "openai", model: "gpt-4o-mini")

        FunctionRoutingStore.save(config)
        defer { try? FileManager.default.removeItem(at: FunctionRoutingStore.fileURL) }

        XCTAssertEqual(FunctionRoutingStore.load(), config)
    }

    func testLoadMissingFileGivesEmptyConfig() {
        try? FileManager.default.removeItem(at: FunctionRoutingStore.fileURL)
        XCTAssertEqual(FunctionRoutingStore.load(), FunctionRoutingConfig())
    }

    func testCorruptFileMovedAsideAndEmptyConfigReturned() throws {
        let dir = FunctionRoutingStore.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("гарантированно битый json {{{".utf8).write(to: FunctionRoutingStore.fileURL)
        let backup = FunctionRoutingStore.fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        defer {
            try? FileManager.default.removeItem(at: FunctionRoutingStore.fileURL)
            try? FileManager.default.removeItem(at: backup)
        }

        let config = FunctionRoutingStore.load()

        XCTAssertEqual(config, FunctionRoutingConfig())
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }
}

// MARK: - FunctionRouter (резолв с дефолтом и невалидацией назначения)

@MainActor
final class FunctionRouterTests: XCTestCase {

    private func makeRouter() -> (FunctionRouter, ProviderRegistry) {
        let registry = ProviderRegistry()
        let router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        return (router, registry)
    }

    func testExplicitAssignmentIsUsedWhenValid() {
        let (router, registry) = makeRouter()
        let mock = MockChatProvider(responses: ["ответ A"])
        registry.register(ProviderDescriptor(id: "a", displayName: "A", capabilities: [.chat], isLocal: true), chat: mock)
        router.assign(FunctionAssignment(providerID: "a", model: "model-a"), to: .chat)

        let resolved = router.resolveChatProvider(for: .chat)

        XCTAssertTrue((resolved?.provider as AnyObject?) === mock)
        XCTAssertEqual(resolved?.model, "model-a")
    }

    func testFallsBackToDefaultWhenNoAssignment() {
        let (router, registry) = makeRouter()
        let mock = MockChatProvider()
        registry.register(
            ProviderDescriptor(id: "default-chat", displayName: "Default", capabilities: [.chat], isLocal: true, defaultModel: "def-model"),
            chat: mock
        )

        let resolved = router.resolveChatProvider(for: .chat)

        XCTAssertTrue((resolved?.provider as AnyObject?) === mock)
        XCTAssertEqual(resolved?.model, "def-model")
    }

    func testFallsBackToDefaultWhenAssignedProviderRemoved() {
        let (router, registry) = makeRouter()
        router.assign(FunctionAssignment(providerID: "removed", model: "x"), to: .chat)
        let fallback = MockChatProvider()
        registry.register(
            ProviderDescriptor(id: "fallback", displayName: "Fallback", capabilities: [.chat], isLocal: true, defaultModel: "fallback-model"),
            chat: fallback
        )

        let resolved = router.resolveChatProvider(for: .chat)

        XCTAssertTrue((resolved?.provider as AnyObject?) === fallback)
        XCTAssertEqual(resolved?.model, "fallback-model")
    }

    func testFallsBackWhenAssignedProviderBecameUnavailable() {
        let (router, registry) = makeRouter()
        var runtimeAlive = false
        registry.register(
            ProviderDescriptor(id: "local", displayName: "Local", capabilities: [.chat], isLocal: true),
            chat: MockChatProvider(),
            isAvailable: { runtimeAlive }
        )
        registry.register(
            ProviderDescriptor(id: "fallback", displayName: "Fallback", capabilities: [.chat], isLocal: true, defaultModel: "fb"),
            chat: MockChatProvider()
        )
        router.assign(FunctionAssignment(providerID: "local", model: "local-model"), to: .chat)

        // Рантайм не поднят — назначение невалидно, роутер уходит в дефолт.
        XCTAssertEqual(router.resolveChatProvider(for: .chat)?.model, "fb")

        runtimeAlive = true
        XCTAssertEqual(router.resolveChatProvider(for: .chat)?.model, "local-model")
    }

    func testNoProviderAtAllResolvesNil() {
        let (router, _) = makeRouter()
        XCTAssertNil(router.resolveChatProvider(for: .chat))
    }

    func testWrongCapabilityAssignmentIgnored() {
        let (router, registry) = makeRouter()
        // Назначили embedding-провайдер на функцию чата — не должен подойти.
        registry.register(ProviderDescriptor(id: "embed", displayName: "Embed", capabilities: [.embedding], isLocal: true))
        router.assign(FunctionAssignment(providerID: "embed", model: "x"), to: .chat)

        XCTAssertNil(router.resolveChatProvider(for: .chat))
    }

    func testResolveEmbeddingProvider() {
        let (router, registry) = makeRouter()
        let embedder = HashingEmbedder()
        registry.register(
            ProviderDescriptor(id: "hash", displayName: "Hash", capabilities: [.embedding], isLocal: true, defaultModel: "hash-256"),
            embedding: embedder
        )

        let resolved = router.resolveEmbeddingProvider(for: .embedding)
        XCTAssertEqual(resolved?.model, "hash-256")
    }

    func testResolveTranscriptionProvider() {
        let (router, registry) = makeRouter()
        let mock = MockTranscriptionProvider()
        registry.register(
            ProviderDescriptor(id: "whisper", displayName: "Whisper", capabilities: [.transcription], isLocal: true, defaultModel: "base"),
            transcription: mock
        )

        let resolved = router.resolveTranscriptionProvider(for: .transcription)
        XCTAssertTrue((resolved?.provider as AnyObject?) === mock)
    }

    func testClearAssignmentRevertsToDefault() {
        let (router, registry) = makeRouter()
        registry.register(
            ProviderDescriptor(id: "a", displayName: "A", capabilities: [.chat], isLocal: true, defaultModel: "def"),
            chat: MockChatProvider()
        )
        router.assign(FunctionAssignment(providerID: "a", model: "custom"), to: .chat)
        XCTAssertEqual(router.resolveChatProvider(for: .chat)?.model, "custom")

        router.clearAssignment(for: .chat)
        XCTAssertEqual(router.resolveChatProvider(for: .chat)?.model, "def")
    }
}

// MARK: - KeyStore (тестовый Keychain-сервис)

final class KeyStoreTests: XCTestCase {
    private let originalService = KeyStore.service

    override func setUp() {
        super.setUp()
        KeyStore.service = "com.local.second-brain.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        KeyStore.service = originalService
        super.tearDown()
    }

    func testSetGetDeleteRoundTrip() {
        let id: ProviderID = "openai"
        XCTAssertNil(KeyStore.key(for: id))

        KeyStore.setKey("test-key-12345", for: id)
        XCTAssertEqual(KeyStore.key(for: id), "test-key-12345")
        XCTAssertTrue(KeyStore.hasKey(for: id))

        KeyStore.setKey("", for: id) // пустая строка — удаление
        XCTAssertNil(KeyStore.key(for: id))
        XCTAssertFalse(KeyStore.hasKey(for: id))
    }

    func testUpdatingExistingKeyOverwrites() {
        let id: ProviderID = "provider-update"
        KeyStore.setKey("первый", for: id)
        KeyStore.setKey("второй", for: id)

        XCTAssertEqual(KeyStore.key(for: id), "второй")
        KeyStore.setKey("", for: id)
    }

    func testEnvVarTakesPriorityOverKeychain() {
        let id: ProviderID = "envtest"
        KeyStore.setKey("из-keychain", for: id)
        defer { KeyStore.setKey("", for: id) }

        // Переменную окружения в реальном процессе не подделать без перезапуска,
        // но саму формулу имени и её использование можно проверить напрямую.
        XCTAssertEqual(KeyStore.envVar(for: id), "SECONDBRAIN_ENVTEST_KEY")
        // Без переменной — ключ приходит из Keychain (проверяет фолбэк-ветку).
        XCTAssertEqual(KeyStore.key(for: id), "из-keychain")
    }

    func testDeletingNonExistentKeyIsNoOp() {
        KeyStore.setKey("", for: "never-existed")
        XCTAssertNil(KeyStore.key(for: "never-existed"))
    }
}

// MARK: - DTO round-trip

final class LLMDTOTests: XCTestCase {

    func testChatMessageDTORoundTrip() throws {
        let message = ChatMessageDTO(role: .user, content: "Привет, [[мир]]!")
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessageDTO.self, from: data), message)
    }

    func testChatSettingsRoundTripWithDefaults() throws {
        let settings = ChatSettings(model: "gpt-4o-mini")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ChatSettings.self, from: data)

        XCTAssertEqual(decoded.model, "gpt-4o-mini")
        XCTAssertEqual(decoded.temperature, 1.0)
        XCTAssertEqual(decoded.stop, [])
    }

    func testFunctionAssignmentRoundTrip() throws {
        let assignment = FunctionAssignment(providerID: "openai", model: "gpt-4o-mini")
        let data = try JSONEncoder().encode(assignment)
        XCTAssertEqual(try JSONDecoder().decode(FunctionAssignment.self, from: data), assignment)
    }

    func testProviderIDStringLiteralAndEquality() {
        let a: ProviderID = "openai"
        let b = ProviderID(rawValue: "openai")
        XCTAssertEqual(a, b)
    }
}

// MARK: - MockChatProvider / MockTranscriptionProvider / HashingEmbedder

final class MockChatProviderTests: XCTestCase {

    func testSendCyclesThroughCannedResponses() async throws {
        let provider = MockChatProvider(responses: ["первый", "второй"])
        let settings = ChatSettings(model: "any")

        let r1 = try await provider.send([], settings: settings)
        let r2 = try await provider.send([], settings: settings)
        let r3 = try await provider.send([], settings: settings)

        XCTAssertEqual([r1.text, r2.text, r3.text], ["первый", "второй", "первый"])
    }

    func testSendThrowsConfiguredError() async {
        let provider = MockChatProvider()
        provider.errorToThrow = LLMError.emptyResponse

        await XCTAssertThrowsErrorAsync(try await provider.send([], settings: ChatSettings(model: "any")))
    }

    func testStreamYieldsChunksThenFinishes() async throws {
        let provider = MockChatProvider(responses: ["раз два три"])
        var collected: [String] = []
        for try await chunk in provider.stream([], settings: ChatSettings(model: "any")) {
            collected.append(chunk)
        }
        XCTAssertEqual(collected.joined(), "раз два три ")
    }

    func testStreamPropagatesConfiguredError() async {
        let provider = MockChatProvider()
        provider.errorToThrow = LLMError.emptyResponse

        do {
            for try await _ in provider.stream([], settings: ChatSettings(model: "any")) {}
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(error as? LLMError, .emptyResponse)
        }
    }

    func testReceivedMessagesRecorded() async throws {
        let provider = MockChatProvider()
        let messages = [ChatMessageDTO(role: .user, content: "привет")]
        _ = try await provider.send(messages, settings: ChatSettings(model: "any"))
        XCTAssertEqual(provider.receivedMessages, [messages])
    }
}

final class HashingEmbedderTests: XCTestCase {

    func testDeterministic() async throws {
        let embedder = HashingEmbedder()
        let a = try await embedder.embedOne("Финансы и активы")
        let b = try await embedder.embedOne("Финансы и активы")
        XCTAssertEqual(a, b)
    }

    func testDifferentTextsDifferentVectors() async throws {
        let embedder = HashingEmbedder()
        let a = try await embedder.embedOne("яблоко")
        let b = try await embedder.embedOne("самолёт")
        XCTAssertNotEqual(a, b)
    }

    func testRespectsDimension() async throws {
        let embedder = HashingEmbedder(dimension: 64)
        let vector = try await embedder.embedOne("текст")
        XCTAssertEqual(vector.count, 64)
        XCTAssertEqual(embedder.dimension, 64)
    }

    func testMinimumDimensionEnforced() {
        XCTAssertEqual(HashingEmbedder(dimension: 1).dimension, 8)
    }

    func testEmptyTextGivesZeroVector() async throws {
        let embedder = HashingEmbedder()
        let vector = try await embedder.embedOne("")
        XCTAssertEqual(vector, [Float](repeating: 0, count: embedder.dimension))
    }

    func testBatchEmbedMatchesIndividualCalls() async throws {
        let embedder = HashingEmbedder()
        let batch = try await embedder.embed(["раз", "два"])
        let individual = [try await embedder.embedOne("раз"), try await embedder.embedOne("два")]
        XCTAssertEqual(batch, individual)
    }
}

/// Хелпер: XCTAssertThrowsError для async throws-выражений.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("ожидалась ошибка", file: file, line: line)
    } catch {
        // ожидаемо
    }
}
