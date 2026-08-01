// StagedInferenceCoreTests.swift — задача 94: чистое ядро декомпозиции primary на стадии.
// renderPrompt таблицей плейсхолдеров (transcript/prev/stage:N, вне диапазона, повтор,
// кириллица); compactOutput (чистый JSON/проза вокруг/```-обёртка/мусор/`}` в строковом
// литерале/пусто); effectiveStages (пустые/пробельные промпты); defaultStages (форма
// четырёх стадий); снисходительные декодеры InferenceStage/StageMetric («из будущего»).

import XCTest
@testable import SecondBrain

final class StagedInferenceCoreTests: XCTestCase {

    // MARK: - renderPrompt

    func testRenderPromptSubstitutesTranscript() {
        let out = StagedInferenceCore.renderPrompt("Текст: {{transcript}}", transcript: "фрагмент",
                                                     previousOutputs: [])
        XCTAssertEqual(out, "Текст: фрагмент")
    }

    func testRenderPromptPrevWithoutPreviousOutputIsEmptyString() {
        let out = StagedInferenceCore.renderPrompt("Пред: [{{prev}}]", transcript: "t", previousOutputs: [])
        XCTAssertEqual(out, "Пред: []")
    }

    func testRenderPromptPrevIsLastPreviousOutput() {
        let out = StagedInferenceCore.renderPrompt("Пред: {{prev}}", transcript: "t",
                                                     previousOutputs: ["a", "b"])
        XCTAssertEqual(out, "Пред: b")
    }

    func testRenderPromptStageOneAndTwoAreOneBasedIndices() {
        let out = StagedInferenceCore.renderPrompt("{{stage:1}} / {{stage:2}}", transcript: "t",
                                                     previousOutputs: ["первая", "вторая"])
        XCTAssertEqual(out, "первая / вторая")
    }

    func testRenderPromptStageOutOfRangeStaysLiteral() {
        let out = StagedInferenceCore.renderPrompt("{{stage:5}}", transcript: "t",
                                                     previousOutputs: ["a", "b"])
        XCTAssertEqual(out, "{{stage:5}}", "5 вне диапазона (только 2 предыдущих выхода) — литерал")
    }

    func testRenderPromptStageZeroStaysLiteral() {
        let out = StagedInferenceCore.renderPrompt("{{stage:0}}", transcript: "t",
                                                     previousOutputs: ["a"])
        XCTAssertEqual(out, "{{stage:0}}", "нумерация 1-based, stage:0 не существует — литерал")
    }

    func testRenderPromptRepeatedPlaceholderReplacedEverywhere() {
        let out = StagedInferenceCore.renderPrompt("{{transcript}} / {{transcript}}", transcript: "T",
                                                     previousOutputs: [])
        XCTAssertEqual(out, "T / T")
    }

    func testRenderPromptSupportsCyrillicSubstitutions() {
        let out = StagedInferenceCore.renderPrompt("Встреча: {{transcript}}\nГоворящие: {{stage:1}}",
                                                     transcript: "Иван и Мария обсудили сроки",
                                                     previousOutputs: ["[\"Иван\", \"Мария\"]"])
        XCTAssertEqual(out, "Встреча: Иван и Мария обсудили сроки\nГоворящие: [\"Иван\", \"Мария\"]")
    }

    func testRenderPromptWithNoPlaceholdersReturnsTemplateUnchanged() {
        let out = StagedInferenceCore.renderPrompt("статичный текст без плейсхолдеров", transcript: "t",
                                                     previousOutputs: ["x"])
        XCTAssertEqual(out, "статичный текст без плейсхолдеров")
    }

    // MARK: - compactOutput

    func testCompactOutputPureJSONObjectParsesOk() {
        let (text, ok) = StagedInferenceCore.compactOutput(#"{"speakers":["Иван"]}"#)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, #"{"speakers":["Иван"]}"#)
    }

    func testCompactOutputExtractsJSONFromSurroundingProse() {
        let raw = #"Вот результат: {"tasks":[{"assignee":null,"task":"сделать"}]} Готово."#
        let (text, ok) = StagedInferenceCore.compactOutput(raw)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, #"{"tasks":[{"assignee":null,"task":"сделать"}]}"#)
    }

    func testCompactOutputExtractsJSONFromMarkdownFence() {
        let raw = "```json\n{\"speakers\":[]}\n```"
        let (text, ok) = StagedInferenceCore.compactOutput(raw)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, "{\"speakers\":[]}")
    }

    func testCompactOutputTotalGarbageTrimsAndMarksParseNotOk() {
        let (text, ok) = StagedInferenceCore.compactOutput("  это точно не JSON вообще  ")
        XCTAssertFalse(ok)
        XCTAssertEqual(text, "это точно не JSON вообще")
    }

    func testCompactOutputEmptyStringTrimsAndMarksParseNotOk() {
        let (text, ok) = StagedInferenceCore.compactOutput("")
        XCTAssertFalse(ok)
        XCTAssertEqual(text, "")
    }

    /// `}` внутри строкового литерала не должен обрубить объект раньше времени —
    /// баланс скобок обязан учитывать кавычки (см. `ConfidencePrompts.firstJSONObjectString`).
    func testCompactOutputClosingBraceInsideStringLiteralDoesNotCutEarly() {
        let raw = #"{"reason": "здесь есть } скобка внутри строки", "ok": true}"#
        let (text, ok) = StagedInferenceCore.compactOutput(raw)
        XCTAssertTrue(ok)
        XCTAssertEqual(text, raw, "весь объект должен быть извлечён целиком, а не обрезан по первой '}' в строке")
    }

    // MARK: - effectiveStages

    func testEffectiveStagesFiltersEmptyAndWhitespacePrompts() {
        let stages = [
            InferenceStage(name: "A", prompt: "непустой"),
            InferenceStage(name: "B", prompt: ""),
            InferenceStage(name: "C", prompt: "   \n\t  "),
            InferenceStage(name: "D", prompt: "тоже непустой"),
        ]
        let effective = StagedInferenceCore.effectiveStages(stages)
        XCTAssertEqual(effective.map(\.name), ["A", "D"])
    }

    func testEffectiveStagesAllEmptyReturnsEmptyArray() {
        let stages = [InferenceStage(name: "A", prompt: ""), InferenceStage(name: "B", prompt: "  ")]
        XCTAssertEqual(StagedInferenceCore.effectiveStages(stages), [])
    }

    func testEffectiveStagesOnEmptyInputReturnsEmptyArray() {
        XCTAssertEqual(StagedInferenceCore.effectiveStages([]), [])
    }

    // MARK: - defaultStages

    func testDefaultStagesHasExactlyFourStages() {
        XCTAssertEqual(StagedInferenceCore.defaultStages().count, 4)
    }

    func testDefaultStagesAllHaveNonEmptyNames() {
        for stage in StagedInferenceCore.defaultStages() {
            XCTAssertFalse(stage.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func testDefaultStagesAllReferenceTranscriptPlaceholder() {
        for stage in StagedInferenceCore.defaultStages() {
            XCTAssertTrue(stage.prompt.contains("{{transcript}}"), "стадия «\(stage.name)» без {{transcript}}")
        }
    }

    func testDefaultStagesFinalStageAssemblesActionItemsFromAllPreviousStages() throws {
        let stages = StagedInferenceCore.defaultStages()
        let final = try XCTUnwrap(stages.last)
        XCTAssertTrue(final.prompt.contains("action_items"))
        XCTAssertTrue(final.prompt.contains("{{stage:1}}"))
        XCTAssertTrue(final.prompt.contains("{{stage:2}}"))
        XCTAssertTrue(final.prompt.contains("{{stage:3}}"))
    }

    // MARK: - InferenceStage decode

    func testInferenceStageDecodesDefaultsFromEmptyObject() throws {
        let data = Data("{}".utf8)
        let stage = try JSONDecoder().decode(InferenceStage.self, from: data)
        XCTAssertEqual(stage.name, "")
        XCTAssertEqual(stage.prompt, "")
    }

    func testInferenceStageRoundTrips() throws {
        let stage = InferenceStage(name: "Говорящие", prompt: "Кто говорит: {{transcript}}")
        let data = try JSONEncoder().encode(stage)
        let decoded = try JSONDecoder().decode(InferenceStage.self, from: data)
        XCTAssertEqual(decoded, stage)
    }

    /// Незнакомое дополнительное поле («из будущего») в объекте стадии не роняет декод —
    /// синтезированный decoder игнорирует неизвестные ключи.
    func testInferenceStageDecodesWithUnknownFutureFieldPresent() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Сборка","prompt":"p","modelHint":"gpt-6"}
        """
        let stage = try JSONDecoder().decode(InferenceStage.self, from: Data(json.utf8))
        XCTAssertEqual(stage.name, "Сборка")
        XCTAssertEqual(stage.prompt, "p")
    }

    // MARK: - StageMetric decode

    func testStageMetricDecodesDefaultsFromEmptyObject() throws {
        let metric = try JSONDecoder().decode(StageMetric.self, from: Data("{}".utf8))
        XCTAssertEqual(metric.name, "")
        XCTAssertEqual(metric.latency, 0)
        XCTAssertEqual(metric.promptTokens, 0)
        XCTAssertEqual(metric.completionTokens, 0)
        XCTAssertTrue(metric.parseOk, "parseOk отсутствует — толерантный дефолт true")
    }

    func testStageMetricRoundTrips() throws {
        let metric = StageMetric(name: "Говорящие", latency: 1.5, promptTokens: 10, completionTokens: 20, parseOk: false)
        let data = try JSONEncoder().encode(metric)
        let decoded = try JSONDecoder().decode(StageMetric.self, from: data)
        XCTAssertEqual(decoded, metric)
    }

    func testStageMetricParseOkAbsentButOtherFieldsPresentDefaultsToTrue() throws {
        let json = """
        {"name":"Сроки","latency":2.5,"promptTokens":5,"completionTokens":7}
        """
        let metric = try JSONDecoder().decode(StageMetric.self, from: Data(json.utf8))
        XCTAssertEqual(metric.name, "Сроки")
        XCTAssertEqual(metric.latency, 2.5)
        XCTAssertTrue(metric.parseOk)
    }

    // MARK: - matchesDefault

    /// Совпадение с шаблоном решает судьбу пользовательских данных: true → в документ
    /// пишется nil («не редактировал», будущие правки шаблона доходят), false → копия.
    func testMatchesDefaultTableOfCases() {
        let template = StagedInferenceCore.defaultStages()

        // Тексты совпадают, id свои — редактор всегда пересоздаёт id.
        let sameTextsNewIDs = template.map { InferenceStage(name: $0.name, prompt: $0.prompt) }
        XCTAssertTrue(StagedInferenceCore.matchesDefault(sameTextsNewIDs), "совпадение текстов при других id")

        var editedPrompt = sameTextsNewIDs
        editedPrompt[1].prompt += " и ещё правило"
        XCTAssertFalse(StagedInferenceCore.matchesDefault(editedPrompt), "правка одного промпта")

        var editedName = sameTextsNewIDs
        editedName[0].name = "Участники"
        XCTAssertFalse(StagedInferenceCore.matchesDefault(editedName), "правка одного имени")

        XCTAssertFalse(StagedInferenceCore.matchesDefault(Array(sameTextsNewIDs.dropLast())), "другое число стадий")
        XCTAssertFalse(StagedInferenceCore.matchesDefault([]), "пустой список")
    }

    // MARK: - RussianPlural

    func testRussianPluralFormTableOfCases() {
        let cases: [(Int, String)] = [
            (1, "стадия"), (2, "стадии"), (4, "стадии"), (5, "стадий"), (11, "стадий"),
            (14, "стадий"), (21, "стадия"), (22, "стадии"), (111, "стадий"), (0, "стадий"),
        ]
        for (count, expected) in cases {
            XCTAssertEqual(RussianPlural.form(count, "стадия", "стадии", "стадий"), expected,
                           "count=\(count)")
        }
    }
}
