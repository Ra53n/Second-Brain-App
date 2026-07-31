// FineTuneOutputsReaderTests.swift — задача 82: разбор baseline/tuned-артефактов (P1).
//
// Реальные файлы репозитория (оба формата outputs.json, оба поколения .md-заголовков),
// путь считается от #filePath — не от текущего каталога процесса. Файлов нет (другой
// чекаут/копия репо без finetune/) — тест пропускается через XCTSkip, не падает.
// Синтетика в temp-каталоге покрывает биты, которых в реальных файлах может не быть:
// битый JSON, отсутствие одной из половин артефакта, отсутствие каталога вовсе.

import XCTest
@testable import SecondBrain

final class FineTuneOutputsReaderTests: XCTestCase {
    private typealias Reader = FineTuneOutputsReader

    /// Корень репозитория — три уровня вверх от Tests/SecondBrainTests/<файл>.swift.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readFixture(_ relativePath: String) throws -> Data {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("\(relativePath) отсутствует в этом чекауте")
        }
        return data
    }

    private func readFixtureText(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(relativePath) отсутствует в этом чекауте")
        }
        return content
    }

    // MARK: - outputs.json, новый формат (finetune/dictation/baseline/)

    func testDictationOutputsJSONNewFormatDecodesMetaAndResults() throws {
        let data = try readFixture("finetune/dictation/baseline/outputs.json")
        guard let parsed = Reader.parseOutputs(json: data) else {
            return XCTFail("outputs.json нового формата не распарсился")
        }
        XCTAssertEqual(parsed.meta.provider, "mlx")
        XCTAssertEqual(parsed.meta.model, "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertNil(parsed.meta.adapter, "baseline без адаптера — nil, не пустая строка")
        XCTAssertEqual(parsed.meta.temperature, 0.3)
        XCTAssertEqual(parsed.texts.count, 10)
    }

    // MARK: - outputs.json, старый плоский формат (finetune/baseline/)

    func testBaselineOutputsJSONOldFlatFormatDecodesWithoutMetadata() throws {
        let data = try readFixture("finetune/baseline/outputs.json")
        guard let parsed = Reader.parseOutputs(json: data) else {
            return XCTFail("outputs.json старого формата не распарсился")
        }
        XCTAssertNil(parsed.meta.provider)
        XCTAssertNil(parsed.meta.model)
        XCTAssertNil(parsed.meta.adapter)
        XCTAssertNil(parsed.meta.temperature)
        XCTAssertEqual(parsed.texts.count, 10, "разбор старого плоского списка не падает")
    }

    // MARK: - .md, новое поколение заголовков ("## Вход", "- провайдер:")

    func testDictationBaselineMDParsesNewHeadings() throws {
        let name = "01-f6c3b7d2-abe5-4b4c-ac77-21632f4651cf.md"
        let content = try readFixtureText("finetune/dictation/baseline/\(name)")
        guard let answer = Reader.parseAnswerFile(name: name, content: content) else {
            return XCTFail("\(name) не распарсился")
        }
        XCTAssertEqual(answer.index, 1, "индекс берётся из имени файла")
        XCTAssertEqual(answer.id, "f6c3b7d2-abe5-4b4c-ac77-21632f4651cf")
        XCTAssertFalse(answer.input.isEmpty)
        XCTAssertFalse(answer.output.isEmpty)
        XCTAssertFalse(answer.reference.isEmpty)
    }

    // MARK: - .md, старое поколение заголовков ("## Задание", "- исходный пост:")

    func testBaselineMDParsesOldHeadings() throws {
        let name = "01-itogi_2025__brief_to_post.md"
        let content = try readFixtureText("finetune/baseline/\(name)")
        guard let answer = Reader.parseAnswerFile(name: name, content: content) else {
            return XCTFail("\(name) не распарсился")
        }
        XCTAssertEqual(answer.index, 1)
        XCTAssertFalse(answer.input.isEmpty)
        XCTAssertFalse(answer.output.isEmpty)
        XCTAssertFalse(answer.reference.isEmpty)
    }

    // MARK: - "###"-заголовки внутри ответа не разрывают секции (ключевой негативный случай)

    func testHashHeadingsInsideBaselineBodyDoNotSplitSections() throws {
        let name = "09-anons_boosty__topic_to_hook.md"
        let content = try readFixtureText("finetune/baseline/\(name)")
        guard let answer = Reader.parseAnswerFile(name: name, content: content) else {
            return XCTFail("\(name) не распарсился")
        }
        XCTAssertTrue(answer.output.contains("###"), "### внутри ответа не должен разрывать секцию \"## Ответ модели\"")
        XCTAssertTrue(answer.output.contains("Новый формат обучения"),
                     "заголовок ### должен остаться внутри output целиком")
    }

    // finetune/tuned/ — в .gitignore (правило 2, CLAUDE.md тестов: ноль зависимости
    // от машины разработчика), тот же случай уже закрыт закоммиченным
    // finetune/baseline/09-anons_boosty__topic_to_hook.md выше.

    // MARK: - Самый короткий эталон в наборе — регрессия «эталон выглядит пустым»

    func testShortestReferenceFileHasNonEmptyReference() throws {
        let name = "03-itogi_2025__topic_to_hook.md"
        let content = try readFixtureText("finetune/baseline/\(name)")
        guard let answer = Reader.parseAnswerFile(name: name, content: content) else {
            return XCTFail("\(name) не распарсился")
        }
        XCTAssertEqual(answer.reference.count, 193,
                       "регрессия: если длина эталона изменилась, обновить фикстуру и проверку")
        XCTAssertFalse(answer.reference.isEmpty, "самый короткий эталон в наборе не должен выглядеть пустым")
        XCTAssertEqual(answer.taskType, "topic_to_hook")
    }

    // MARK: - Синтетика: битый ввод и отсутствующие части

    func testCorruptOutputsJSONReturnsNil() {
        XCTAssertNil(Reader.parseOutputs(json: Data("{ не json совсем".utf8)))
    }

    func testEmptyOldFormatArrayDecodesToEmptyTextsNotNil() {
        guard let parsed = Reader.parseOutputs(json: Data("[]".utf8)) else {
            return XCTFail("пустой массив старого формата — валидный, но пустой результат")
        }
        XCTAssertEqual(parsed.texts, [:])
        XCTAssertNil(parsed.meta.provider)
    }

    func testFileWithoutReferenceSectionReturnsNilAnswer() {
        let content = """
        # x

        ## Задание

        Задание текст

        ## Ответ модели

        Ответ текст
        """
        XCTAssertNil(Reader.parseAnswerFile(name: "01-x.md", content: content),
                     "нет секции \"Эталон\" — answer не собирается")
    }

    func testFilenameWithoutLeadingNumberReturnsNil() {
        let content = """
        ## Задание

        Задание текст

        ## Ответ модели

        Ответ текст

        ## Эталон (текст автора)

        Эталон текст
        """
        XCTAssertNil(Reader.parseAnswerFile(name: "no-number.md", content: content))
    }

    func testMissingInputSectionYieldsEmptyInputNotFailure() {
        let content = """
        ## Ответ модели

        Ответ текст

        ## Эталон (текст автора)

        Эталон текст
        """
        let answer = Reader.parseAnswerFile(name: "02-x.md", content: content)
        XCTAssertEqual(answer?.input, "", "нет ни \"Вход\", ни \"Задание\" — пустая строка, не падение")
        XCTAssertEqual(answer?.output, "Ответ текст")
    }
}

// MARK: - FineTuneOutputsIO — синтетика в temp-каталоге, реальные файлы не нужны

final class FineTuneOutputsIOTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainTests-FineTuneOutputsIO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMissingDirectoryReturnsNilWithoutThrowing() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        XCTAssertNil(FineTuneOutputsIO.readSnapshot(directory: missing))
    }

    func testCorruptOutputsJSONWithoutMDFallsBackToEmptyMetaAndTexts() throws {
        try Data("{ не json совсем".utf8).write(to: tempDir.appendingPathComponent("outputs.json"))
        let snapshot = try XCTUnwrap(FineTuneOutputsIO.readSnapshot(directory: tempDir))
        XCTAssertNil(snapshot.meta.provider)
        XCTAssertEqual(snapshot.answers, [])
        XCTAssertEqual(snapshot.textsOnly, [:])
    }

    func testOutputsJSONWithoutMDFilesExposesTextsOnly() throws {
        let json = #"{"provider":"mlx","model":"m","adapter":null,"temperature":0.5,"results":[{"id":"a","text":"текст a"}]}"#
        try Data(json.utf8).write(to: tempDir.appendingPathComponent("outputs.json"))
        let snapshot = try XCTUnwrap(FineTuneOutputsIO.readSnapshot(directory: tempDir))
        XCTAssertEqual(snapshot.meta.provider, "mlx")
        XCTAssertEqual(snapshot.answers, [], "нет .md — нет разобранных ответов")
        XCTAssertEqual(snapshot.textsOnly, ["a": "текст a"])
    }

    func testMDFilesWithoutOutputsJSONParsesAnswersWithNilMeta() throws {
        let md = """
        # x

        ## Задание

        Задание текст

        ## Ответ модели

        Ответ текст

        ## Эталон (текст автора)

        Эталон текст
        """
        try Data(md.utf8).write(to: tempDir.appendingPathComponent("01-x.md"))
        let snapshot = try XCTUnwrap(FineTuneOutputsIO.readSnapshot(directory: tempDir))
        XCTAssertNil(snapshot.meta.provider)
        XCTAssertEqual(snapshot.answers.count, 1)
        XCTAssertEqual(snapshot.answers.first?.output, "Ответ текст")
        XCTAssertEqual(snapshot.textsOnly, [:], "answers непусты — тексты из outputs.json уже не нужны")
    }
}
