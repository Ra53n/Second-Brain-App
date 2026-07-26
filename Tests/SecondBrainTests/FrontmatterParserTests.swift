// FrontmatterParserTests.swift — довесок к тестам FrontmatterParser (задача 58).
//
// Имя класса FrontmatterParserTests уже занято в LinksTests.swift (задача 04) —
// здесь класс FrontmatterParserAdditionalTests, чтобы не столкнуться именем.
// LinksTests уже покрывает: типы скаляров (string/number/date/inline-список/
// блок-список), отсутствие frontmatter, битый (без закрывающего ---), raw-строки
// + байт-точный round-trip без мутаций, subscript set (новое поле/обновление),
// схлопывание в body при удалении последнего поля. Здесь — то, что тонко: round-
// trip ЧЕРЕЗ мутацию (set→serialize→parse), кириллица в ключах, unquote (парные/
// непарные кавычки, в т.ч. внутри блок-списка), наивный comma-split инлайн-
// списка, отрицательные/нулевые числа, невалидная календарная дата, subscript
// remove отсутствующего ключа и set в документ без frontmatter вовсе, raw-строка
// «: без ключа», пустой блок frontmatter (round-trip через hasEmptyFrontmatterBlock,
// задача 69).

import XCTest
@testable import SecondBrain

final class FrontmatterParserAdditionalTests: XCTestCase {

    // MARK: - Round-trip через мутацию

    /// LinksTests проверяет serialized()==text на НЕизменённом документе; здесь —
    /// после subscript-мутаций: serialize → parse должен вернуть те же типизированные
    /// значения, а повторный parse(serialized) — совпасть с документом целиком.
    func testParseSerializeParseRoundTripAfterMutation() {
        let original = """
        ---
        title: Старое
        ---
        Тело заметки.
        """
        var doc = FrontmatterParser.parse(original)
        doc["title"] = .string("Новое")
        doc["count"] = .number(3)
        doc["date"] = .date(FrontmatterParser.dateFormatter.date(from: "2026-01-15")!)
        doc["tags"] = .list(["раз", "два"])

        let reparsed = FrontmatterParser.parse(doc.serialized())

        XCTAssertEqual(reparsed["title"], .string("Новое"))
        XCTAssertEqual(reparsed["count"], .number(3))
        XCTAssertEqual(reparsed["date"], .date(FrontmatterParser.dateFormatter.date(from: "2026-01-15")!))
        XCTAssertEqual(reparsed["tags"], .list(["раз", "два"]))
        XCTAssertEqual(reparsed.body, "Тело заметки.")
        XCTAssertEqual(reparsed, doc, "повторный parse(serialized()) идемпотентен")
    }

    // MARK: - Кириллица в ключах

    func testCyrillicKeysParseAndRoundTrip() {
        let text = """
        ---
        заголовок: Встреча
        приоритет: 5
        ---
        Тело.
        """
        var doc = FrontmatterParser.parse(text)
        XCTAssertEqual(doc["заголовок"], .string("Встреча"))
        XCTAssertEqual(doc["приоритет"], .number(5))
        XCTAssertEqual(doc.serialized(), text)

        doc["новыйключ"] = .string("значение")
        let reparsed = FrontmatterParser.parse(doc.serialized())
        XCTAssertEqual(reparsed["новыйключ"], .string("значение"), "кириллический ключ переживает set→serialize→parse")
    }

    // MARK: - unquote

    func testUnquoteStripsMatchingDoubleAndSingleQuotes() {
        let text = """
        ---
        double: "В кавычках"
        single: 'Одинарные'
        ---
        Тело.
        """
        let doc = FrontmatterParser.parse(text)
        XCTAssertEqual(doc["double"], .string("В кавычках"))
        XCTAssertEqual(doc["single"], .string("Одинарные"))
    }

    /// Непарные кавычки (нет закрывающей, либо открывающая/закрывающая разного
    /// типа) НЕ снимаются — unquote требует совпадения quote и на префиксе, и на
    /// суффиксе одновременно.
    func testUnquoteLeavesMismatchedQuotesUntouched() {
        let text = """
        ---
        a: "не закрыта
        b: "
        c: 'смешанные"
        ---
        Тело.
        """
        let doc = FrontmatterParser.parse(text)
        XCTAssertEqual(doc["a"], .string("\"не закрыта"), "открывающая без закрывающей остаётся с кавычкой")
        XCTAssertEqual(doc["b"], .string("\""), "одна кавычка без пары (count<2) не трогается")
        XCTAssertEqual(doc["c"], .string("'смешанные\""), "открывающая/закрывающая разного типа — не пара")
    }

    func testBlockListItemsAreUnquoted() {
        let text = """
        ---
        tags:
          - "первый"
          - 'второй'
          - третий
        ---
        Тело.
        """
        let doc = FrontmatterParser.parse(text)
        XCTAssertEqual(doc["tags"], .list(["первый", "второй", "третий"]), "unquote применяется и к элементам блок-списка")
    }

    /// НАХОДКА (документированное ограничение модуля — заголовок файла явно
    /// предупреждает «не полноценный YAML», не новый баг): инлайн-список режется
    /// наивным split(separator: ",") по КАЖДОЙ запятой, включая ту, что внутри
    /// кавычек. "a,b" в кавычках разваливается на два фрагмента с оборванными
    /// кавычками вместо одного элемента "a,b".
    func testInlineListNaiveCommaSplitBreaksQuotedCommas() {
        let text = """
        ---
        tags: ["a,b", c]
        ---
        Тело.
        """
        let doc = FrontmatterParser.parse(text)
        XCTAssertEqual(doc["tags"], .list(["\"a", "b\"", "c"]),
                       "запятая внутри кавычек рвёт элемент на два — фактическое поведение, не выдуманное")
    }

    // MARK: - subscript

    func testSubscriptRemoveNonexistentKeyIsNoOp() {
        var doc = FrontmatterParser.parse("---\ntitle: Заметка\n---\nТело.")
        let before = doc
        doc["нет такого ключа"] = nil
        XCTAssertEqual(doc, before, "удаление отсутствующего ключа не меняет документ")
    }

    func testSubscriptSetAddsFrontmatterToBodyOnlyDocument() {
        var doc = FrontmatterParser.parse("Заметка без метаданных вообще.")
        XCTAssertTrue(doc.entries.isEmpty)

        doc["title"] = .string("Новая")

        XCTAssertEqual(doc.serialized(), "---\ntitle: Новая\n---\nЗаметка без метаданных вообще.")
        let reparsed = FrontmatterParser.parse(doc.serialized())
        XCTAssertEqual(reparsed["title"], .string("Новая"))
        XCTAssertEqual(reparsed.body, "Заметка без метаданных вообще.")
    }

    // MARK: - Числа и даты: границы

    func testNegativeAndZeroNumbersParseAsNumber() {
        let text = """
        ---
        debt: -150.5
        balance: 0
        streak: -3
        ---
        Тело.
        """
        let doc = FrontmatterParser.parse(text)
        XCTAssertEqual(doc["debt"], .number(-150.5))
        XCTAssertEqual(doc["balance"], .number(0))
        XCTAssertEqual(doc["streak"], .number(-3))
    }

    /// Дата, похожая по форме на YYYY-MM-DD, но невалидная как календарная дата
    /// (месяц/день вне диапазона) — «значение из будущего» для нелениентного
    /// DateFormatter: возвращает nil, парсер откатывается на .string, не падает.
    func testDateShapedButInvalidCalendarDateFallsBackToString() {
        let text = """
        ---
        a: 2026-13-45
        b: 2026-02-30
        ---
        Тело.
        """
        let doc = FrontmatterParser.parse(text)
        XCTAssertEqual(doc["a"], .string("2026-13-45"), "месяц 13 не существует")
        XCTAssertEqual(doc["b"], .string("2026-02-30"), "30 февраля не существует")
    }

    // MARK: - Raw-строки и пустой блок

    /// Строка формально содержит «:», но начинается с него — класс символов
    /// ключа требует [^\s:] первым символом, поэтому строка не парсится и
    /// сохраняется как raw-запись (key: nil), round-trip не портится.
    func testLineStartingWithColonIsPreservedAsRaw() {
        let text = """
        ---
        title: Заметка
        : значение без ключа
        ---
        Тело.
        """
        let doc = FrontmatterParser.parse(text)

        XCTAssertEqual(doc["title"], .string("Заметка"))
        XCTAssertTrue(doc.entries.contains { $0.key == nil && $0.rawLines == [": значение без ключа"] })
        XCTAssertEqual(doc.serialized(), text, "raw-строка переживает round-trip")
    }

    /// «title:» (без значения, без списка ниже) и «title: ""» (явная пустая
    /// строка в кавычках) дают ОДИНАКОВОЕ типизированное значение .string(""),
    /// но через разные ветки парсера — и с разными rawLines, различие в
    /// исходном форматировании не схлопывается.
    func testEmptyValueAndEmptyQuotedStringParseToSameTypeButDifferentRaw() {
        let bareColon = FrontmatterParser.parse("---\ntitle:\n---\nТело.")
        let emptyQuoted = FrontmatterParser.parse("---\ntitle: \"\"\n---\nТело.")

        XCTAssertEqual(bareColon["title"], .string(""))
        XCTAssertEqual(emptyQuoted["title"], .string(""))
        XCTAssertEqual(bareColon.entries[0].rawLines, ["title:"])
        XCTAssertEqual(emptyQuoted.entries[0].rawLines, ["title: \"\""])
    }

    /// НАХОДКА (задача 69, fixed): «пустой» блок frontmatter («---\n---\n») парсился
    /// в entries=[] неотличимо от «frontmatter вообще нет», поэтому serialized()
    /// теряла маркеры. Флаг hasEmptyFrontmatterBlock различает эти состояния;
    /// тест фиксирует byte-exact round-trip как регрессию на этот баг.
    func testEmptyFrontmatterBlockRoundTripsCorrectly() {
        let text = "---\n---\nТело."
        let doc = FrontmatterParser.parse(text)

        XCTAssertTrue(doc.entries.isEmpty, "пустой блок парсится в entries=[]")
        XCTAssertEqual(doc.body, "Тело.")
        XCTAssertTrue(doc.hasEmptyFrontmatterBlock, "флаг различает пустой блок от отсутствия фронтматтера")
        XCTAssertEqual(doc.serialized(), text, "сериализация воспроизводит маркеры ---\\n---\\n")

        let reparsed = FrontmatterParser.parse(doc.serialized())
        XCTAssertEqual(reparsed, doc, "parse → serialize → parse даёт идентичный результат")
        XCTAssertTrue(reparsed.hasEmptyFrontmatterBlock, "флаг переживает round-trip")
    }

    /// Документ без frontmatter вовсе имеет hasEmptyFrontmatterBlock=false,
    /// отличие от пустого блока проверяется при сериализации.
    func testDocumentWithoutFrontmatterDoesNotGetEmptyBlockMarkers() {
        let text = "Просто текст без frontmatter."
        let doc = FrontmatterParser.parse(text)

        XCTAssertTrue(doc.entries.isEmpty)
        XCTAssertFalse(doc.hasEmptyFrontmatterBlock, "отсутствие фронтматтера имеет флаг=false")
        XCTAssertEqual(doc.serialized(), text, "сериализация НЕ добавляет маркеры для документа без фронтматтера")
    }

    /// Когда к документу с пустым фронтматтером добавляют поле через subscript,
    /// фронтматтер становится непустым и сохраняется как обычный блок.
    func testAddingFieldToEmptyFrontmatterBlockPreservesFrontmatter() {
        var doc = FrontmatterParser.parse("---\n---\nТело.")
        XCTAssertTrue(doc.entries.isEmpty)
        XCTAssertTrue(doc.hasEmptyFrontmatterBlock)

        doc["title"] = .string("Новый")

        XCTAssertFalse(doc.entries.isEmpty, "после добавления поля entries не пустые")
        XCTAssertTrue(doc.hasEmptyFrontmatterBlock, "флаг остаётся на месте (не меняется subscript)")
        XCTAssertEqual(doc.serialized(), "---\ntitle: Новый\n---\nТело.", "фронтматтер сохраняется с новым полем")

        let reparsed = FrontmatterParser.parse(doc.serialized())
        XCTAssertFalse(reparsed.hasEmptyFrontmatterBlock, "переразобранный документ уже с полем, флаг=false")
        XCTAssertEqual(reparsed["title"], .string("Новый"))
    }
}
