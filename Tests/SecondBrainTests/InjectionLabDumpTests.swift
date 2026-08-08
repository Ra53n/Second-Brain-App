// InjectionLabDumpTests.swift — выгрузка реальных промптов, определений
// инструментов и тул-результатов для живого прогона лаборатории инъекций
// (задача 100, стенд security/injection-lab).
//
// Сети здесь нет: тест собирает ровно те строки, что приложение отправляет
// модели, и пишет их в JSON. Живой запрос к провайдеру делает live_probe.py —
// так стенд гоняет настоящий код сборки, а не его пересказ на Python.
//
// Тест — no-op без переменной окружения INJECTION_LAB_DUMP (путь выходного
// файла), поэтому обычный ./scripts/test.sh его не замечает.

import XCTest
@testable import SecondBrain

final class InjectionLabDumpTests: XCTestCase {

    /// Корень стенда: Tests/SecondBrainTests/… → на два уровня вверх до репозитория.
    private var labRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SecondBrainTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // репозиторий
            .appendingPathComponent("security/injection-lab", isDirectory: true)
    }

    func testDumpLiveHarnessInput() throws {
        guard let outPath = ProcessInfo.processInfo.environment["INJECTION_LAB_DUMP"] else {
            return // обычный прогон тестов: ничего не делаем
        }

        let vault = labRoot.appendingPathComponent("vault", isDirectory: true)
        let q3 = try String(contentsOf: vault.appendingPathComponent("Q3-планы.md"), encoding: .utf8)
        let report = try String(contentsOf: vault.appendingPathComponent("Отчёт-анализа.md"),
                                encoding: .utf8)
        let statusPage = try String(contentsOf: labRoot.appendingPathComponent("web/status.html"),
                                    encoding: .utf8)

        // Вектор A: rag_search в tool-режиме. База одна — папка стенда.
        let base = KnowledgeBase(id: "lab", kind: .folder, name: "injection-lab",
                                 path: vault.path)
        let ragDefinition = try XCTUnwrap(RagSearchTool.definition(bases: [base]))
        // Хиты — реальные чанки заражённой заметки реальным чанкером.
        let hits = MarkdownChunker.chunk(text: q3, filePath: "Q3-планы.md").map {
            KnowledgeHit(baseID: base.id, baseName: base.name, filePath: "Q3-планы.md",
                         headingPath: $0.headingPath, text: $0.text, score: 0.9)
        }
        let ragResult = RagSearchTool.formatResult(hits: hits).text

        // Вектор B: read_file. Результат инструмента — сырой текст файла (GitTools.swift:293).
        let readFileTool = ReadFileTool()

        // Вектор C: fetch_url. Тул-результат — сырой HTML web/status.html (та же
        // страница, что реально отдаёт lab_server.py); директива инструментов — та
        // же, что у B (fetch_url живёт в projectTools вместе с read_file).
        let fetchUrlTool = FetchUrlTool()

        let systemRagOnly = ChatPromptBuilder.systemPrompt(
            tools: ChatPromptBuilder.ragToolDirective)
        let systemFilesOnly = ChatPromptBuilder.systemPrompt(
            tools: ChatPromptBuilder.fileToolsDirective(mode: .ask, rootPath: vault.path))
        let systemWebOnly = ChatPromptBuilder.systemPrompt(
            tools: ChatPromptBuilder.fileToolsDirective(mode: .ask, rootPath: vault.path))

        // baseline = состояние ДО задачи 99: только роль, без правил безопасности,
        // и сырые тул-результаты без оговорки «это ДАННЫЕ». Так выглядел агент,
        // пока защиты не было вообще — с ним и снимаем «до».
        let rawRagResult = "Результаты поиска по заметкам:\n\n" + q3

        // Тумблер «Защита ВЫКЛ» (задача 101) — те же функции с secure: false.
        // Ими проверяем, что режим в приложении даёт ровно baseline-поведение.
        let insecureRagOnly = ChatPromptBuilder.systemPrompt(
            tools: ChatPromptBuilder.ragToolDirective, secure: false)
        let insecureFilesOnly = ChatPromptBuilder.systemPrompt(
            tools: ChatPromptBuilder.fileToolsDirective(mode: .ask, rootPath: vault.path),
            secure: false)
        let insecureWebOnly = ChatPromptBuilder.systemPrompt(
            tools: ChatPromptBuilder.fileToolsDirective(mode: .ask, rootPath: vault.path),
            secure: false)
        let insecureRagResult = RagSearchTool.formatResult(hits: hits, secure: false).text

        let dump = LabDump(
            basePrompt: ChatPromptBuilder.basePrompt,
            systemPrompts: [
                "A-rag": systemRagOnly,
                "B-file": systemFilesOnly,
                "C-web": systemWebOnly,
            ],
            insecureSystemPrompts: [
                "A-rag": insecureRagOnly,
                "B-file": insecureFilesOnly,
                "C-web": insecureWebOnly,
            ],
            tools: [
                "A-rag": [DumpedTool(ragDefinition)],
                "B-file": [DumpedTool(name: readFileTool.name,
                                      description: readFileTool.description,
                                      schema: readFileTool.parameters)],
                "C-web": [DumpedTool(name: fetchUrlTool.name,
                                     description: fetchUrlTool.description,
                                     schema: fetchUrlTool.parameters)],
            ],
            toolResults: [
                "A-rag": ragResult,
                "B-file": report,
                "C-web": statusPage,
            ],
            rawToolResults: [
                "A-rag": rawRagResult,
                "B-file": report,
                "C-web": statusPage,
            ],
            insecureToolResults: [
                "A-rag": insecureRagResult,
                "B-file": report,
                "C-web": statusPage,
            ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(dump).write(to: URL(fileURLWithPath: outPath), options: .atomic)
    }
}

// MARK: - DTO выгрузки

private struct DumpedTool: Encodable {
    var name: String
    var description: String
    var schema: JSONValue

    init(name: String, description: String, schema: JSONValue) {
        self.name = name
        self.description = description
        self.schema = schema
    }

    init(_ definition: ToolDefinition) {
        self.init(name: definition.name, description: definition.description,
                  schema: definition.schema)
    }
}

private struct LabDump: Encodable {
    var basePrompt: String
    var systemPrompts: [String: String]
    /// Те же промпты при выключённом тумблере защиты (задача 101).
    var insecureSystemPrompts: [String: String]
    var tools: [String: [DumpedTool]]
    var toolResults: [String: String]
    var rawToolResults: [String: String]
    var insecureToolResults: [String: String]
}
