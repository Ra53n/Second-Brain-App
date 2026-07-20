// MeetingPipelineTests.swift — оркестрация пайплайна встречи на моках:
// полный прогон (с преднастроенным названием и через диалог), resume после
// «краша» (контекст из JSON середины пайплайна продолжает с нужного шага),
// ретраи с лимитом, валидация папки, заметка на диске.

import AVFoundation
import XCTest
@testable import SecondBrain

@MainActor
final class MeetingPipelineTests: XCTestCase {
    var vaultDir: URL!
    var storeFile: URL!
    var store: MeetingStore!
    var registry: ProviderRegistry!
    var router: FunctionRouter!
    var chat: MockChatProvider!
    var transcription: MockTranscriptionProvider!

    /// Ответ LLM по умолчанию — полный формат.
    static let goodLLMResponse = """
    TITLE: Синк по релизу
    FOLDER: Работа/Релизы
    SUMMARY:
    Обсудили релиз, решили катить в пятницу.
    """

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: vaultDir.appendingPathComponent("Meetings/_recordings"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: vaultDir.appendingPathComponent("Работа/Релизы"),
            withIntermediateDirectories: true)
        storeFile = vaultDir.appendingPathComponent("meetings-test.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    /// Пайплайн с мок-провайдерами; локальные (без ключей), сразу доступны.
    private func makePipeline(chatResponses: [String] = [goodLLMResponse]) -> MeetingPipeline {
        store = MeetingStore(fileURL: storeFile)
        registry = ProviderRegistry()
        chat = MockChatProvider(responses: chatResponses)
        transcription = MockTranscriptionProvider(
            result: Transcript(fullText: "привет, обсуждаем релиз",
                               segments: [TranscriptSegment(text: "привет, обсуждаем релиз",
                                                            start: 0, end: 3)],
                               language: "ru"))
        registry.register(
            ProviderDescriptor(id: "mock", displayName: "Mock",
                               capabilities: [.chat, .transcription],
                               isLocal: true, defaultModel: "mock-1"),
            chat: chat, transcription: transcription)
        router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        return MeetingPipeline(
            router: router,
            store: store,
            vaultURL: { [vaultDir] in vaultDir },
            vaultFolders: { ["Работа", "Работа/Релизы"] },
            settings: { MeetingSettings() })
    }

    /// Контекст с реально существующим файлом записи.
    @discardableResult
    private func makeContext(presetTitle: String? = nil,
                             base: String = "2026-07-12 10-30") throws -> MeetingContext {
        let audio = "\(base).m4a"
        FileManager.default.createFile(
            atPath: vaultDir.appendingPathComponent("Meetings/_recordings/\(audio)").path,
            contents: Data("m4a".utf8))
        let context = MeetingContext(recordingBase: base,
                                     audioFiles: [audio],
                                     recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
                                     duration: 300,
                                     presetTitle: presetTitle)
        store.upsert(context)
        return context
    }

    /// Пишет секунду синуса как AAC-в-CAF (как настоящий рекордер) — для теста
    /// нормализации формата перед отправкой в облачный STT.
    private func makeCAF(at url: URL, seconds: Double = 1.0) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let pointer = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            pointer[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
        try file.write(from: buffer)
    }

    // MARK: - Полные прогоны

    func testFullRunWithPresetTitleSkipsDialog() async throws {
        let pipeline = makePipeline()
        let context = try makeContext(presetTitle: "1:1 с Петей")
        await pipeline.run(context.id)

        let final = store.context(id: context.id)!
        XCTAssertEqual(final.state, .done)
        XCTAssertEqual(final.status, .finished)
        XCTAssertEqual(final.transcripts.first?.transcript.fullText, "привет, обсуждаем релиз")
        XCTAssertEqual(final.summary, "Обсудили релиз, решили катить в пятницу.")
        // Название — заданное заранее, не LLM-ное.
        let note = vaultDir.appendingPathComponent(final.notePath!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(note.lastPathComponent.contains("1:1 с Петей".replacingOccurrences(of: ":", with: "-")))
        let content = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(content.contains("# 1-1 с Петей"))
        XCTAssertTrue(content.contains("[00:00] привет, обсуждаем релиз"))
    }

    func testRunWithoutPresetStopsAtDialogThenConfirms() async throws {
        let pipeline = makePipeline()
        let context = try makeContext()
        await pipeline.run(context.id)

        var mid = store.context(id: context.id)!
        XCTAssertEqual(mid.state, .awaitingTitle, "без названия — ждём пользователя")
        XCTAssertEqual(mid.status, .awaitingUser)
        XCTAssertEqual(mid.suggestedTitle, "Синк по релизу")
        XCTAssertEqual(mid.suggestedFolder, "Работа/Релизы", "папка существует — принята")
        XCTAssertFalse(mid.folderWasInvalid)

        await pipeline.confirmTitle(context.id, title: "Мой вариант", folder: "Работа/Релизы")
        mid = store.context(id: context.id)!
        XCTAssertEqual(mid.state, .done)
        XCTAssertTrue(mid.notePath!.hasPrefix("Работа/Релизы/"))
        XCTAssertTrue(mid.notePath!.contains("Мой вариант"))
    }

    func testInvalidFolderFromLLMFallsBack() async throws {
        let response = "TITLE: Т\nFOLDER: Несуществующая/Папка\nSUMMARY:\nК."
        let pipeline = makePipeline(chatResponses: [response])
        let context = try makeContext()
        await pipeline.run(context.id)

        let mid = store.context(id: context.id)!
        XCTAssertEqual(mid.suggestedFolder,
                       MeetingNoteWriter.defaultFolder(for: mid.recordedAt))
        XCTAssertTrue(mid.folderWasInvalid, "пользователь увидит замену папки")
    }

    // MARK: - Resume после «краша»

    func testResumeFromTranscribedSkipsTranscription() async throws {
        let pipeline = makePipeline()
        var context = try makeContext(presetTitle: "Встреча")
        // Симулируем краш после транскрипции: контекст в .transcribed из «JSON».
        context.state = .transcribed
        context.transcripts = [TrackTranscript(
            fileName: context.audioFiles[0],
            transcript: Transcript(fullText: "готовый транскрипт", segments: [], language: "ru"))]
        store.upsert(context)

        await pipeline.run(context.id)

        let final = store.context(id: context.id)!
        XCTAssertEqual(final.state, .done)
        // Транскрипция НЕ вызывалась повторно — транскрипт остался прежним.
        XCTAssertEqual(final.transcripts.first?.transcript.fullText, "готовый транскрипт")
        XCTAssertEqual(chat.receivedMessages.count, 1, "только summary-запрос")
    }

    func testResumeFromAwaitingTitleSurvivesRestart() async throws {
        // «Рестарт»: контекст в awaitingTitle грузится из файла новым стором.
        let pipeline = makePipeline()
        var context = try makeContext()
        context.state = .awaitingTitle
        context.status = .awaitingUser
        context.summary = "конспект"
        context.suggestedTitle = "Название от ИИ"
        store.upsert(context)

        // Новый стор читает тот же файл (как после перезапуска приложения).
        let reloaded = MeetingStore(fileURL: storeFile)
        XCTAssertEqual(reloaded.context(id: context.id)?.state, .awaitingTitle)
        XCTAssertEqual(reloaded.context(id: context.id)?.status, .awaitingUser,
                       "awaitingUser — не running, нормализация не трогает")
        _ = pipeline // прогон не нужен: проверяем восстановление точки ожидания
    }

    // MARK: - Ошибки и ретраи

    func testTranscriptionFailureRetriesThenFails() async throws {
        let pipeline = makePipeline()
        let context = try makeContext(presetTitle: "Т")
        transcription.errorToThrow = LLMError.badStatus(code: 500, message: "провайдер лёг")

        await pipeline.run(context.id)

        let final = store.context(id: context.id)!
        XCTAssertEqual(final.state, .failed)
        XCTAssertEqual(final.status, .failed)
        XCTAssertEqual(final.failedStage, .transcribing)
        XCTAssertNotNil(final.errorText)
    }

    func testRetryAfterFailureContinuesFromFailedStage() async throws {
        let pipeline = makePipeline()
        let context = try makeContext(presetTitle: "Т")
        transcription.errorToThrow = LLMError.badStatus(code: 500, message: "временно")
        await pipeline.run(context.id)
        XCTAssertEqual(store.context(id: context.id)?.state, .failed)

        // Провайдер ожил — «Повторить» доводит до конца.
        transcription.errorToThrow = nil
        await pipeline.run(context.id)
        let final = store.context(id: context.id)!
        XCTAssertEqual(final.state, .done)
        XCTAssertEqual(final.status, .finished)
    }

    func testNoTranscriptionProviderFailsWithClearError() async throws {
        let pipeline = makePipeline()
        // Реестр без транскрипции: перерегистрируем только чат.
        registry = ProviderRegistry()
        registry.register(
            ProviderDescriptor(id: "chat-only", displayName: "Chat",
                               capabilities: [.chat], isLocal: true, defaultModel: "m"),
            chat: chat)
        router = FunctionRouter(registry: registry, config: FunctionRoutingConfig())
        let isolated = MeetingPipeline(router: router, store: store,
                                       vaultURL: { [vaultDir] in vaultDir },
                                       vaultFolders: { [] })
        let context = try makeContext(presetTitle: "Т")
        await isolated.run(context.id)
        let final = store.context(id: context.id)!
        XCTAssertEqual(final.state, .failed)
        XCTAssertEqual(final.errorText, MeetingError.noTranscriptionProvider.errorDescription)
        _ = pipeline
    }

    func testMissingAudioFileFails() async throws {
        let pipeline = makePipeline()
        let context = MeetingContext(recordingBase: "нет-такой",
                                     audioFiles: ["нет-такой.m4a"],
                                     recordedAt: .now, duration: 10,
                                     presetTitle: "Т")
        store.upsert(context)
        await pipeline.run(context.id)
        let final = store.context(id: context.id)!
        XCTAssertEqual(final.state, .failed)
        XCTAssertEqual(final.errorText,
                       MeetingError.audioFileMissing("нет-такой.m4a").errorDescription)
    }

    // MARK: - Нормализация формата аудио

    /// Сирота .caf (после краха/сбоя перепаковки) нормализуется во временный
    /// .m4a перед отправкой в облачный STT — иначе Deepgram отвечает
    /// «corrupt or unsupported data». Исходный .caf не трогаем, temp убираем.
    func testCafTrackIsNormalizedToM4ABeforeTranscription() async throws {
        let pipeline = makePipeline()
        let base = "2026-07-12 11-00"
        let caf = "\(base).caf"
        let cafURL = vaultDir.appendingPathComponent("Meetings/_recordings/\(caf)")
        try makeCAF(at: cafURL)
        let context = MeetingContext(recordingBase: base,
                                     audioFiles: [caf],
                                     recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
                                     duration: 5,
                                     presetTitle: "Встреча из CAF")
        store.upsert(context)

        await pipeline.run(context.id)

        let final = store.context(id: context.id)!
        XCTAssertEqual(final.state, .done, "запись из .caf прошла пайплайн целиком")
        // Провайдер получил перепакованный .m4a, а не исходный .caf.
        let received = transcription.receivedAudioURL
        XCTAssertEqual(received?.pathExtension, "m4a")
        XCTAssertNotEqual(received?.lastPathComponent, caf)
        // Временный .m4a убран после отправки.
        if let received {
            XCTAssertFalse(FileManager.default.fileExists(atPath: received.path))
        }
        // Исходный .caf не тронут (источник истины — vault).
        XCTAssertTrue(FileManager.default.fileExists(atPath: cafURL.path))
    }

    /// Штатный .m4a уходит в провайдер как есть — без лишней перепаковки.
    func testM4ATrackSentAsIsWithoutRepack() async throws {
        let pipeline = makePipeline()
        let context = try makeContext(presetTitle: "Обычная встреча")
        await pipeline.run(context.id)
        let received = transcription.receivedAudioURL
        XCTAssertEqual(received?.lastPathComponent, context.audioFiles[0],
                       ".m4a отправляется напрямую, тем же путём")
    }

    // MARK: - Map-reduce

    func testLongTranscriptGoesThroughMapReduce() async throws {
        // Транскрипт длиннее порога: N чанк-запросов + финальный summary.
        let longText = String(repeating: "слово ", count: 8000) // ~48 тыс. символов
        let pipeline = makePipeline(chatResponses: [
            "конспект части 1", "конспект части 2", Self.goodLLMResponse
        ])
        transcription.result = Transcript(fullText: longText, segments: [], language: "ru")
        let context = try makeContext(presetTitle: "Долгая встреча")
        await pipeline.run(context.id)

        let final = store.context(id: context.id)!
        XCTAssertEqual(final.state, .done)
        XCTAssertEqual(chat.receivedMessages.count, 3, "2 map-запроса + 1 финальный")
        // Финальный запрос собран из конспектов, а не из сырого транскрипта.
        let finalPrompt = chat.receivedMessages.last!.last!.content
        XCTAssertTrue(finalPrompt.contains("конспект части 1"))
        XCTAssertFalse(finalPrompt.contains(longText))
    }
}
