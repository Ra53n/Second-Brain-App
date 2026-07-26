// SettingsTests.swift — тесты задачи 17 (настройки).
//
// Покрытие по критериям приёмки:
//  - миграция из старых мест хранения (UserDefaults задачи 16 → SettingsStore),
//    значения переезжают и не теряются;
//  - сериализация SettingsStore (round-trip, снисходительное декодирование,
//    карантин битого файла);
//  - валидация роутинга при недоступном провайдере (RoutingValidator);
//  - дополнительно: расширение MeetingSettings (старый JSON грузится,
//    точечный update не стирает чужие поля — регрессия для бага перезаписи)
//    и чистые части KeyVerifier (запрос без секрета в URL, трактовка статуса).

import XCTest
@testable import SecondBrain

// MARK: - AppSettings: сериализация и миграция формата

final class AppSettingsCodableTests: XCTestCase {

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.showsDotItems = true
        settings.restoreLastVault = false
        settings.autoBackupMinutes = 15
        settings.localIdleMinutes = 30
        settings.projectRepoPath = "/tmp/repo"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testOldJSONWithoutNewFieldsLoadsWithDefaults() throws {
        // Старый файл знает только один ключ — остальные обязаны получить дефолты.
        let old = #"{"autoBackupMinutes": 5}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.autoBackupMinutes, 5)
        XCTAssertFalse(decoded.showsDotItems)
        XCTAssertTrue(decoded.restoreLastVault)
        XCTAssertEqual(decoded.localIdleMinutes, 10)
        XCTAssertEqual(decoded.projectRepoPath, "", "поле задачи 21 получает дефолт")
        XCTAssertEqual(decoded.helpContextBudget, 32_000, "поле задачи 80 получает дефолт")
    }

    func testOldJSONWithoutHelpContextBudgetLoadsWithDefault() throws {
        // Старый файл до задачи 80 без helpContextBudget обязан загружаться с дефолтом 32000.
        let old = #"{"autoBackupMinutes": 5, "projectRepoPath": "/tmp/repo"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.helpContextBudget, 32_000)
        XCTAssertEqual(decoded.autoBackupMinutes, 5)
        XCTAssertEqual(decoded.projectRepoPath, "/tmp/repo")
    }

    func testHelpContextBudgetOutOfRangeClampedOnDecode() throws {
        // Вручную отредактированный/устаревший settings.json может содержать значение
        // за границами (отрицательное, ноль, огромное) — декодер обязан зажать его,
        // а не пропустить в обход UI-валидации.
        let cases: [(json: Int, expected: Int, name: String)] = [
            (-100, 1_000, "отрицательное"),
            (0, 1_000, "ноль"),
            (500, 1_000, "ниже минимума"),
            (2_000_000, 1_000_000, "выше максимума"),
            (Int.max, 1_000_000, "экстремум"),
        ]
        for c in cases {
            let json = #"{"helpContextBudget": \#(c.json)}"#
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.helpContextBudget, c.expected, c.name)
        }
    }
}

// MARK: - SettingsStore: загрузка, миграция, карантин

@MainActor
final class SettingsStoreTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private let suiteName = "SettingsStoreTests"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("settings.json")
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFirstLaunchMigratesLegacyAutoBackupInterval() {
        // Старое место (задача 16): интервал авто-бэкапа в UserDefaults.
        defaults.set(30, forKey: SettingsStore.legacyAutoBackupKey)
        let store = SettingsStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(store.settings.autoBackupMinutes, 30)
        // Мигрированное значение сразу сохранено в файл.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testExistingFilePreferredOverLegacyDefaults() throws {
        // Файл уже есть — legacy-значение игнорируется (миграция одноразовая).
        var existing = AppSettings()
        existing.autoBackupMinutes = 5
        try JSONEncoder().encode(existing).write(to: fileURL)
        defaults.set(60, forKey: SettingsStore.legacyAutoBackupKey)

        let store = SettingsStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(store.settings.autoBackupMinutes, 5)
    }

    func testChangePersistsAndReloads() throws {
        let store = SettingsStore(fileURL: fileURL, defaults: defaults)
        store.settings.showsDotItems = true
        store.settings.localIdleMinutes = 60

        let reloaded = SettingsStore(fileURL: fileURL, defaults: defaults)
        XCTAssertTrue(reloaded.settings.showsDotItems)
        XCTAssertEqual(reloaded.settings.localIdleMinutes, 60)
    }

    func testHelpContextBudgetPersistsAndReloads() throws {
        let store = SettingsStore(fileURL: fileURL, defaults: defaults)
        store.settings.helpContextBudget = 64_000

        let reloaded = SettingsStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(reloaded.settings.helpContextBudget, 64_000)
    }

    func testCorruptFileQuarantinedAndDefaultsUsed() throws {
        try Data("не json".utf8).write(to: fileURL)
        let store = SettingsStore(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(store.settings, AppSettings())
        let quarantine = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }
}

// MARK: - RoutingValidator

@MainActor
final class RoutingValidatorTests: XCTestCase {

    /// Реестр с локальными провайдерами (isLocal — без похода в Keychain)
    /// и управляемой доступностью.
    private func makeRegistry(chatAvailable: Bool) -> ProviderRegistry {
        let registry = ProviderRegistry()
        registry.register(
            ProviderDescriptor(id: "чат", displayName: "Чат-провайдер",
                               capabilities: [.chat], isLocal: true, defaultModel: "m"),
            chat: MockChatProvider(),
            isAvailable: { chatAvailable }
        )
        registry.register(
            ProviderDescriptor(id: "звук", displayName: "Транскрибатор",
                               capabilities: [.transcription], isLocal: true, defaultModel: "w"),
            transcription: MockTranscriptionProvider(),
            isAvailable: { true }
        )
        return registry
    }

    func testNoAssignmentsNoIssues() {
        let issues = RoutingValidator.issues(config: FunctionRoutingConfig(),
                                             registry: makeRegistry(chatAvailable: true))
        XCTAssertTrue(issues.isEmpty)
    }

    func testValidAssignmentNoIssues() {
        var config = FunctionRoutingConfig()
        config[.chat] = FunctionAssignment(providerID: "чат", model: "m")
        let issues = RoutingValidator.issues(config: config,
                                             registry: makeRegistry(chatAvailable: true))
        XCTAssertTrue(issues.isEmpty)
    }

    func testUnavailableProviderProducesWarning() {
        // Критерий приёмки: предупреждение при недоступном назначении.
        var config = FunctionRoutingConfig()
        config[.chat] = FunctionAssignment(providerID: "чат", model: "m")
        let issues = RoutingValidator.issues(config: config,
                                             registry: makeRegistry(chatAvailable: false))
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].function, .chat)
        XCTAssertTrue(issues[0].message.contains("недоступен"))
    }

    func testUnknownProviderProducesWarning() {
        var config = FunctionRoutingConfig()
        config[.embedding] = FunctionAssignment(providerID: "удалённый", model: "x")
        let issues = RoutingValidator.issues(config: config,
                                             registry: makeRegistry(chatAvailable: true))
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("не найден"))
    }

    func testCapabilityMismatchProducesWarning() {
        // Транскрибатор назначен на чат — способность не совпадает.
        var config = FunctionRoutingConfig()
        config[.chat] = FunctionAssignment(providerID: "звук", model: "w")
        let issues = RoutingValidator.issues(config: config,
                                             registry: makeRegistry(chatAvailable: true))
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("не поддерживает"))
    }
}

// MARK: - MeetingSettings: миграция и точечный update

final class MeetingSettingsMigrationTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-settings-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("meeting_settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testOldJSONWithOnlyFilingRulesLoads() throws {
        // Файл, записанный до задачи 17: только filingRules.
        try Data(#"{"filingRules": "1:1 → Команда/1на1"}"#.utf8).write(to: fileURL)
        let settings = MeetingSettingsStore.load(from: fileURL)
        XCTAssertEqual(settings.filingRules, "1:1 → Команда/1на1")
        XCTAssertEqual(settings.defaultFolder, "")
        XCTAssertNil(settings.defaultSource)
    }

    func testUpdatePreservesOtherFields() {
        // Регрессия: редактор одного поля не должен стирать остальные
        // (старый код сохранял новый MeetingSettings() целиком).
        MeetingSettingsStore.update(at: fileURL) {
            $0.filingRules = "правила"
            $0.defaultFolder = "Встречи"
            $0.defaultSource = .both
        }
        MeetingSettingsStore.update(at: fileURL) { $0.filingRules = "новые правила" }

        let settings = MeetingSettingsStore.load(from: fileURL)
        XCTAssertEqual(settings.filingRules, "новые правила")
        XCTAssertEqual(settings.defaultFolder, "Встречи")
        XCTAssertEqual(settings.defaultSource, .both)
    }

    func testCustomDefaultFolderUsedAsFallback() {
        // Папка по умолчанию из настроек заменяет штатную Meetings/YYYY-MM.
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let (folder, wasInvalid) = MeetingNoteWriter.resolveFolder(
            suggested: "Несуществующая",
            existingFolders: ["Работа"],
            date: date,
            customDefault: "Встречи/Архив/")
        XCTAssertEqual(folder, "Встречи/Архив")
        XCTAssertTrue(wasInvalid)

        // Пустая настройка — прежнее поведение.
        let (standard, _) = MeetingNoteWriter.resolveFolder(
            suggested: nil, existingFolders: [], date: date, customDefault: "")
        XCTAssertTrue(standard.hasPrefix("Meetings/"))
    }
}

// MARK: - KeyVerifier: чистые части

final class KeyVerifierTests: XCTestCase {

    func testVerdictMapping() {
        XCTAssertEqual(KeyVerifier.verdict(statusCode: 200), .ok)
        XCTAssertEqual(KeyVerifier.verdict(statusCode: 204), .ok)
        XCTAssertEqual(KeyVerifier.verdict(statusCode: 401), .invalidKey)
        XCTAssertEqual(KeyVerifier.verdict(statusCode: 403), .invalidKey)
        XCTAssertEqual(KeyVerifier.verdict(statusCode: 500), .failed("HTTP 500"))
    }

    func testRequestNeverPutsKeyInURL() {
        // Секрет — только в заголовке (URL попадает в логи/прокси).
        for id: ProviderID in [OpenAIProvider.id, GeminiProvider.id,
                               DeepgramProvider.id, AssemblyAIProvider.id] {
            let request = KeyVerifier.request(for: id, key: "SECRET-123")
            XCTAssertNotNil(request, "нет запроса проверки для \(id)")
            XCTAssertFalse(request!.url!.absoluteString.contains("SECRET-123"),
                           "ключ в URL у \(id)")
            let headers = request!.allHTTPHeaderFields ?? [:]
            XCTAssertTrue(headers.values.contains { $0.contains("SECRET-123") },
                          "ключ не передан в заголовке у \(id)")
        }
    }

    func testUnknownProviderHasNoRequest() {
        XCTAssertNil(KeyVerifier.request(for: "неизвестный", key: "x"))
    }
}
