// CodeRegionDetectorTests.swift — тесты детектора код-регионов редактора (задача 58).
//
// Покрыто: excludedRanges на пустой строке, незакрытом/не-с-начала-строки блоке,
// одном/нескольких/соседних инлайн-спанах, инлайне через перевод строки (не матчится),
// кириллице+эмодзи (UTF-16 диапазоны); isExcluded на касании/перекрытии на 1 символ/
// нулевой длине/пустом списке исключений.

import XCTest
@testable import SecondBrain

final class CodeRegionDetectorExcludedRangesTests: XCTestCase {

    func testEmptyStringHasNoExcludedRanges() {
        XCTAssertTrue(CodeRegionDetector.excludedRanges(in: "").isEmpty)
    }

    /// НАХОДКА: незакрытый ``` не даёт НИКАКОЙ защиты содержимому после себя —
    /// регэксп codeBlockRegex требует парную закрывающую ``` на начале строки;
    /// без неё совпадения нет вообще (не «до конца файла», а «нет совпадения»).
    /// Остальные лёгкие парсеры (wikilinks и т.п.) отработают этот текст как обычный.
    func testUnclosedCodeBlockFenceExcludesNothing() {
        let text = "```\nкод без закрывающей тройки\nещё текст"
        XCTAssertTrue(CodeRegionDetector.excludedRanges(in: text).isEmpty)
    }

    func testClosedCodeBlockExcludesWholeFenceIncludingContent() {
        let text = "текст до\n```\nстрока 1\nстрока 2\n```\nтекст после"
        let ranges = CodeRegionDetector.excludedRanges(in: text)
        let ns = text as NSString

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ns.substring(with: ranges[0]), "```\nстрока 1\nстрока 2\n```")
    }

    /// ``` не в начале строки — не код-блок (anchorsMatchLines требует ^ на строке).
    /// Три «голых» подряд идущих backtick без соседних символов также не могут
    /// стать инлайн-кодом: между любыми двумя выбранными backtick-границами
    /// «внутренность» сама оказывается backtick-ом, а `[^`\n]+` его запрещает.
    func testTripleBacktickNotAtLineStartIsNotACodeBlockNorInline() {
        let text = "текст ``` ещё текст без второго тройного"
        XCTAssertTrue(CodeRegionDetector.excludedRanges(in: text).isEmpty)
    }

    /// Та же ситуация, но с контентом внутри тройных backtick: inlineCodeRegex
    /// НЕ игнорирует эту тройку целиком — она случайно матчит средний одиночный
    /// backtick-«спан» ``code`` (второй и третий backtick тройки + контент +
    /// первый backtick закрывающей тройки). Документирует приблизительность
    /// детектора, а не полноценный markdown-парсинг.
    func testTripleBacktickMidLineAccidentallyMatchesInnerInlineSpan() {
        let text = "See ```code``` example"
        let ranges = CodeRegionDetector.excludedRanges(in: text)
        let ns = text as NSString

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ns.substring(with: ranges[0]), "`code`")
    }

    func testSingleInlineCodeSpanMatchesWholeSpan() {
        let text = "текст `код` тут"
        let ranges = CodeRegionDetector.excludedRanges(in: text)
        let ns = text as NSString

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ns.substring(with: ranges[0]), "`код`")
    }

    /// Ключевой случай из задачи: инлайн-код не может содержать перевод строки —
    /// паттерн `[^`\n]+` явно исключает \n, поэтому пара backtick через \n не матчится.
    func testInlineCodeDoesNotSpanNewline() {
        let withNewline = "`abc\ndef`"
        XCTAssertTrue(CodeRegionDetector.excludedRanges(in: withNewline).isEmpty, "перевод строки внутри — не матчится")

        let withoutNewline = "`abcdef`"
        let ranges = CodeRegionDetector.excludedRanges(in: withoutNewline)
        XCTAssertEqual(ranges.count, 1, "тот же текст без \\n — матчится")
    }

    /// Соседние инлайн-спаны без разделителя: `one``two` — четыре backtick подряд
    /// (не тройка), regex укладывает их в два касающихся друг друга матча.
    func testAdjacentInlineSpansWithoutSeparatorBothMatch() {
        let text = "`one``two`"
        let ranges = CodeRegionDetector.excludedRanges(in: text)
        let ns = text as NSString

        XCTAssertEqual(ranges.count, 2)
        let sorted = ranges.sorted { $0.location < $1.location }
        XCTAssertEqual(ns.substring(with: sorted[0]), "`one`")
        XCTAssertEqual(ns.substring(with: sorted[1]), "`two`")
        XCTAssertEqual(NSMaxRange(sorted[0]), sorted[1].location, "спаны касаются вплотную")
    }

    func testMultipleInlineSpansSeparatedByTextAllMatch() {
        let text = "`a` и `b` и `c`"
        let ranges = CodeRegionDetector.excludedRanges(in: text)
        let ns = text as NSString
        let substrings = ranges.sorted { $0.location < $1.location }.map { ns.substring(with: $0) }

        XCTAssertEqual(substrings, ["`a`", "`b`", "`c`"])
    }

    /// Известный класс крашей модуля: диапазоны обязаны быть в UTF-16 code units,
    /// а не в Swift Character count. Эмодзи — суррогатная пара (2 code units).
    func testCyrillicAndEmojiInlineCodeProduceValidUTF16Ranges() {
        let text = "до `код 🚀 кириллица` после"
        let ranges = CodeRegionDetector.excludedRanges(in: text)
        let ns = text as NSString

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ns.substring(with: ranges[0]), "`код 🚀 кириллица`")
        XCTAssertLessThanOrEqual(NSMaxRange(ranges[0]), ns.length)
    }

    func testCyrillicAndEmojiCodeBlockProducesValidUTF16Range() {
        let text = "```\nКириллица и 🚀 эмодзи внутри\n```"
        let ranges = CodeRegionDetector.excludedRanges(in: text)
        let ns = text as NSString

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ns.substring(with: ranges[0]), text)
    }
}

final class CodeRegionDetectorIsExcludedTests: XCTestCase {

    func testFalseWhenExcludedListIsEmpty() {
        XCTAssertFalse(CodeRegionDetector.isExcluded(NSRange(location: 0, length: 5), from: []))
    }

    func testTrueWhenRangesOverlap() {
        let excluded = [NSRange(location: 0, length: 5)]
        XCTAssertTrue(CodeRegionDetector.isExcluded(NSRange(location: 2, length: 3), from: excluded))
    }

    /// Касание (конец одного == начало другого) — это НЕ пересечение:
    /// NSIntersectionRange для смежных диапазонов даёт length 0.
    func testFalseWhenRangesOnlyTouch() {
        let excluded = [NSRange(location: 0, length: 5)]
        XCTAssertFalse(CodeRegionDetector.isExcluded(NSRange(location: 5, length: 3), from: excluded))
    }

    func testTrueWhenOverlapIsExactlyOneCharacter() {
        let excluded = [NSRange(location: 0, length: 5)]
        XCTAssertTrue(CodeRegionDetector.isExcluded(NSRange(location: 4, length: 3), from: excluded))
    }

    /// Диапазон нулевой длины (курсор без выделения) не пересекается ни с чем,
    /// даже если формально «внутри» исключённого региона — у него нет протяжённости.
    func testFalseForZeroLengthRangeEvenInsideExcludedRegion() {
        let excluded = [NSRange(location: 0, length: 5)]
        XCTAssertFalse(CodeRegionDetector.isExcluded(NSRange(location: 2, length: 0), from: excluded))
    }

    func testTrueWhenAnyOfMultipleExcludedRangesOverlaps() {
        let excluded = [NSRange(location: 0, length: 3), NSRange(location: 10, length: 3)]
        XCTAssertTrue(CodeRegionDetector.isExcluded(NSRange(location: 9, length: 3), from: excluded))
        XCTAssertFalse(CodeRegionDetector.isExcluded(NSRange(location: 4, length: 3), from: excluded))
    }
}
