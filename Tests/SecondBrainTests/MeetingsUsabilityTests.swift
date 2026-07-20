// MeetingsUsabilityTests.swift — тесты задачи 41: надёжная транскрипция m4a,
// диаризация в саммари, дефолт «оба входа» и переключатель провайдера
// транскрипции в разделе «Встречи».

import XCTest
@testable import SecondBrain

// MARK: - MIME по расширению (общий AudioMIME для всех облачных STT)

final class AudioMIMETests: XCTestCase {

    func testMimeTypeByExtension() {
        // Регрессия задачи 41: MIME был захардкожен audio/mpeg для любого
        // файла — наши записи .m4a уходили с неверным типом.
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.m4a")), "audio/mp4")
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.MP4")), "audio/mp4")
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.wav")), "audio/wav")
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.mp3")), "audio/mpeg")
    }

    func testMimeTypeCoversAdditionalFormats() {
        // Расширенная таблица (фикс транскрипции): распространённые контейнеры
        // получают корректный тип, а не универсальный audio/mpeg.
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.flac")), "audio/flac")
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.ogg")), "audio/ogg")
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.webm")), "audio/webm")
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.caf")), "audio/x-caf")
    }

    func testMimeTypeUnknownExtensionFallsBackToMpeg() {
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec.xyz")), "audio/mpeg")
        XCTAssertEqual(AudioMIME.type(for: URL(fileURLWithPath: "/a/rec")), "audio/mpeg")
    }

    func testCloudSTTReadinessExcludesInternalCaf() {
        // Внутренний CAF нельзя слать в облако напрямую — его нормализуют в .m4a.
        XCTAssertFalse(AudioMIME.isCloudSTTReady(URL(fileURLWithPath: "/a/rec.caf")))
        XCTAssertTrue(AudioMIME.isCloudSTTReady(URL(fileURLWithPath: "/a/rec.m4a")))
        XCTAssertTrue(AudioMIME.isCloudSTTReady(URL(fileURLWithPath: "/a/rec.wav")))
    }
}

// MARK: - Query-параметры Deepgram

final class DeepgramQueryItemsTests: XCTestCase {

    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    func testQueryIncludesModelDiarizationAndLanguage() {
        // Регрессия задачи 41: без model= Deepgram брал БАЗОВУЮ модель,
        // хотя дескриптор обещал nova-2 — качество на русском страдало.
        let items = DeepgramProvider.queryItems(model: "nova-2", language: "ru", hints: nil)
        XCTAssertEqual(value(items, "model"), "nova-2")
        XCTAssertEqual(value(items, "language"), "ru")
        XCTAssertEqual(value(items, "diarize"), "true")
        XCTAssertEqual(value(items, "smart_format"), "true")
        XCTAssertEqual(value(items, "punctuate"), "true")
        XCTAssertNil(value(items, "keywords"))
    }

    func testQueryAppendsKeywordsForHints() {
        let items = DeepgramProvider.queryItems(model: "nova-2", language: "ru", hints: "Kafka, ретро")
        XCTAssertEqual(value(items, "keywords"), "Kafka, ретро")
    }

    func testEmptyHintsDoNotAppendKeywords() {
        let items = DeepgramProvider.queryItems(model: "nova-2", language: "ru", hints: "")
        XCTAssertNil(value(items, "keywords"))
    }

    func testDefaultModelMatchesDescriptorRegistration() {
        XCTAssertEqual(DeepgramProvider().model, DeepgramProvider.defaultModel)
    }
}

// MARK: - Диаризация доходит до саммари (combinedTranscriptText)

final class CombinedTranscriptTextTests: XCTestCase {

    private func context(transcripts: [TrackTranscript]) -> MeetingContext {
        var c = MeetingContext(recordingBase: "rec", audioFiles: transcripts.map(\.fileName),
                               recordedAt: .distantPast, duration: 10)
        c.transcripts = transcripts
        return c
    }

    func testSingleTrackWithSpeakerSegmentsUsesSegments() {
        // Метки «Speaker N:» живут только в сегментах — fullText их теряет.
        let transcript = Transcript(
            fullText: "привет как дела всё хорошо",
            segments: [
                TranscriptSegment(text: "Speaker 0: привет как дела", start: 0, end: 1),
                TranscriptSegment(text: "Speaker 1: всё хорошо", start: 1.5, end: 2)
            ],
            language: "ru")
        let c = context(transcripts: [TrackTranscript(fileName: "rec.m4a", transcript: transcript)])
        XCTAssertEqual(c.combinedTranscriptText, "Speaker 0: привет как дела\nSpeaker 1: всё хорошо")
    }

    func testSingleTrackWithoutSegmentsFallsBackToFullText() {
        let transcript = Transcript(fullText: "просто текст", segments: [], language: "ru")
        let c = context(transcripts: [TrackTranscript(fileName: "rec.m4a", transcript: transcript)])
        XCTAssertEqual(c.combinedTranscriptText, "просто текст")
    }

    func testTwoTracksKeepLabelsAndSegments() {
        let mic = Transcript(fullText: "мой вопрос", segments: [], language: "ru")
        let system = Transcript(
            fullText: "ответ собеседника",
            segments: [TranscriptSegment(text: "Speaker 0: ответ собеседника", start: 0, end: 1)],
            language: "ru")
        let c = context(transcripts: [
            TrackTranscript(fileName: "rec.m4a", transcript: mic),
            TrackTranscript(fileName: "rec\(RecordingNamer.systemTrackSuffix).m4a", transcript: system)
        ])
        XCTAssertEqual(c.combinedTranscriptText,
                       "[Микрофон]\nмой вопрос\n\n[Собеседники (система)]\nSpeaker 0: ответ собеседника")
    }

    func testEmptyTranscriptsGiveEmptyText() {
        XCTAssertEqual(context(transcripts: []).combinedTranscriptText, "")
    }
}

// MARK: - Дефолт источника записи «оба входа»

final class ResolvedDefaultSourceTests: XCTestCase {

    func testNilDefaultsToBothWhenSystemAudioSupported() {
        XCTAssertEqual(MeetingSettings().resolvedDefaultSource(systemAudioSupported: true), .both)
    }

    func testNilDegradesToMicrophoneWithoutSystemAudio() {
        XCTAssertEqual(MeetingSettings().resolvedDefaultSource(systemAudioSupported: false), .microphone)
    }

    func testExplicitChoiceWins() {
        var settings = MeetingSettings()
        settings.defaultSource = .system
        XCTAssertEqual(settings.resolvedDefaultSource(systemAudioSupported: true), .system)
    }

    func testExplicitSystemDegradesToMicrophoneWithoutSupport() {
        var settings = MeetingSettings()
        settings.defaultSource = .system
        XCTAssertEqual(settings.resolvedDefaultSource(systemAudioSupported: false), .microphone)
    }

    func testExplicitMicrophoneUnaffectedBySupport() {
        var settings = MeetingSettings()
        settings.defaultSource = .microphone
        XCTAssertEqual(settings.resolvedDefaultSource(systemAudioSupported: false), .microphone)
    }

    func testOldJSONWithoutFieldResolvesToBoth() throws {
        // Старый meeting_settings.json без defaultSource: nil → «оба входа».
        let settings = try JSONDecoder().decode(
            MeetingSettings.self, from: Data(#"{"filingRules": "x"}"#.utf8))
        XCTAssertNil(settings.defaultSource)
        XCTAssertEqual(settings.resolvedDefaultSource(systemAudioSupported: true), .both)
    }
}

// MARK: - Переключатель провайдера транскрипции

@MainActor
final class TranscriptionRoutePresenterTests: XCTestCase {

    private var registry: ProviderRegistry!
    private var router: FunctionRouter!
    private var storeURL: URL!

    override func setUp() async throws {
        registry = ProviderRegistry()
        // temp storeURL (задача 33): assign() не должен трогать живой routing.json.
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-tests-\(UUID().uuidString).json")
        router = FunctionRouter(registry: registry,
                                config: FunctionRoutingConfig(),
                                storeURL: storeURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func registerLocalTranscriber(id: ProviderID, name: String,
                                          available: Bool = true) {
        registry.register(
            ProviderDescriptor(id: id, displayName: name,
                               capabilities: [.transcription],
                               isLocal: true, defaultModel: "\(id.rawValue)-model"),
            transcription: MockTranscriptionProvider(),
            isAvailable: { available })
    }

    func testNoProvidersGivesNoAvailableAndWarningTitle() {
        let presenter = TranscriptionRoutePresenter(router: router)
        XCTAssertFalse(presenter.hasAvailableProvider)
        XCTAssertEqual(presenter.chipTitle, "Транскрипция: нет провайдера")
        XCTAssertTrue(presenter.choices.isEmpty)
    }

    func testAutoShowsFirstAvailableProvider() {
        registerLocalTranscriber(id: "wh", name: "Whisper")
        registerLocalTranscriber(id: "dg", name: "Deepgram")
        let presenter = TranscriptionRoutePresenter(router: router)
        XCTAssertTrue(presenter.hasAvailableProvider)
        XCTAssertEqual(presenter.chipTitle, "Транскрипция: Авто (Whisper)")
    }

    func testUnavailableProviderSkippedInAutoButListedDisabled() {
        registerLocalTranscriber(id: "wh", name: "Whisper", available: false)
        registerLocalTranscriber(id: "dg", name: "Deepgram")
        let presenter = TranscriptionRoutePresenter(router: router)
        XCTAssertEqual(presenter.chipTitle, "Транскрипция: Авто (Deepgram)")
        XCTAssertEqual(presenter.choices.map(\.isAvailable), [false, true])
    }

    func testSelectAssignsProviderWithItsDefaultModel() {
        registerLocalTranscriber(id: "wh", name: "Whisper")
        registerLocalTranscriber(id: "dg", name: "Deepgram")
        let presenter = TranscriptionRoutePresenter(router: router)

        presenter.select("dg")

        XCTAssertEqual(router.assignment(for: .transcription),
                       FunctionAssignment(providerID: "dg", model: "dg-model"))
        XCTAssertEqual(presenter.chipTitle, "Транскрипция: Deepgram")
        XCTAssertEqual(presenter.choices.filter(\.isSelected).map(\.id), ["dg"])
    }

    func testSelectAutoClearsAssignment() {
        registerLocalTranscriber(id: "wh", name: "Whisper")
        let presenter = TranscriptionRoutePresenter(router: router)
        presenter.select("wh")

        presenter.selectAuto()

        XCTAssertNil(router.assignment(for: .transcription))
        XCTAssertEqual(presenter.chipTitle, "Транскрипция: Авто (Whisper)")
    }

    func testStaleAssignmentShownAsAuto() {
        // Явно назначенный провайдер стал недоступен — чип честно показывает
        // «Авто (X)»: именно так поведёт себя роутер при вызове.
        registerLocalTranscriber(id: "wh", name: "Whisper")
        registry.register(
            ProviderDescriptor(id: "gone", displayName: "Отозванный",
                               capabilities: [.transcription],
                               isLocal: true, defaultModel: "m"),
            transcription: MockTranscriptionProvider(),
            isAvailable: { false })
        router.assign(FunctionAssignment(providerID: "gone", model: "m"), to: .transcription)

        let presenter = TranscriptionRoutePresenter(router: router)
        XCTAssertEqual(presenter.chipTitle, "Транскрипция: Авто (Whisper)")
        XCTAssertTrue(presenter.hasAvailableProvider)
    }
}

// MARK: - Навигация из ошибок пайплайна в настройки

final class MeetingErrorNavigationTests: XCTestCase {

    func testNoTranscriptionProviderLeadsToProvidersTab() throws {
        let text = try XCTUnwrap(MeetingError.noTranscriptionProvider.errorDescription)
        XCTAssertEqual(MeetingErrorNavigation.settingsTab(forErrorText: text), .providers)
    }

    func testNoChatProviderLeadsToProvidersTab() throws {
        let text = try XCTUnwrap(MeetingError.noChatProvider.errorDescription)
        XCTAssertEqual(MeetingErrorNavigation.settingsTab(forErrorText: text), .providers)
    }

    func testUnrelatedErrorGivesNoTab() {
        XCTAssertNil(MeetingErrorNavigation.settingsTab(forErrorText: "Сеть недоступна"))
        XCTAssertNil(MeetingErrorNavigation.settingsTab(forErrorText: ""))
    }
}
