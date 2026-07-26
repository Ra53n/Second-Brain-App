// LinksTests.swift — тесты модуля Links (задача 04).
//
// Покрытие (по критериям приёмки):
//  - WikilinkParser: все формы ссылок, код-блоки, кириллица/пробелы/эмодзи,
//    пустые и вложенные скобки;
//  - FrontmatterParser: типы значений, битый frontmatter, round-trip без потерь;
//  - LinkIndex: построение на temp-vault, обновление, резолв дублей, backlinks;
//  - FuzzyMatch: ранжирование префикс/подстрока/подпоследовательность.
// Стиль — как PromptParsingTests в MA: round-trip + edge cases.

import XCTest
@testable import SecondBrain

// MARK: - WikilinkParser

final class WikilinkParserTests: XCTestCase {

    func testAllLinkForms() {
        let text = "[[Заметка]] и [[Заметка|алиас]] и [[Заметка#Секция]] и [[Заметка#Секция|алиас]]"
        let links = WikilinkParser.parse(text)

        XCTAssertEqual(links.count, 4)
        XCTAssertEqual(links[0].target, "Заметка")
        XCTAssertNil(links[0].heading)
        XCTAssertNil(links[0].alias)
        XCTAssertEqual(links[1].alias, "алиас")
        XCTAssertEqual(links[2].heading, "Секция")
        XCTAssertEqual(links[3].heading, "Секция")
        XCTAssertEqual(links[3].alias, "алиас")
    }

    func testDisplayText() {
        XCTAssertEqual(WikilinkParser.parse("[[Имя|Алиас]]")[0].displayText, "Алиас")
        XCTAssertEqual(WikilinkParser.parse("[[Имя#Глава]]")[0].displayText, "Имя › Глава")
        XCTAssertEqual(WikilinkParser.parse("[[Имя]]")[0].displayText, "Имя")
    }

    func testTargetWithPathAndSpacesAndEmoji() {
        let links = WikilinkParser.parse("[[Финансы и активы/Бюджет 2026]] [[Планы 🚀]]")

        XCTAssertEqual(links[0].target, "Финансы и активы/Бюджет 2026")
        XCTAssertEqual(links[1].target, "Планы 🚀")
    }

    func testLinksInCodeAreIgnored() {
        let text = """
        [[настоящая]]
        `[[в инлайн-коде]]`
        ```
        [[в код-блоке]]
        ```
        """
        let links = WikilinkParser.parse(text)

        XCTAssertEqual(links.map(\.target), ["настоящая"])
    }

    func testEmptyAndWhitespaceLinksIgnored() {
        XCTAssertTrue(WikilinkParser.parse("[[]]").isEmpty)
        XCTAssertTrue(WikilinkParser.parse("[[   ]]").isEmpty)
        XCTAssertTrue(WikilinkParser.parse("[[#Заголовок]]").isEmpty) // без цели — вне объёма
    }

    func testNestedBracketsTakeInnermost() {
        // «[[a[[b]]» — валидна только внутренняя [[b]].
        let links = WikilinkParser.parse("[[a[[b]]")
        XCTAssertEqual(links.map(\.target), ["b"])
    }

    func testLinkDoesNotSpanLines() {
        XCTAssertTrue(WikilinkParser.parse("[[раз\nдва]]").isEmpty)
    }

    func testRangeCoversWholeLinkInUTF16() {
        let text = "до [[Ссылка|алиас]] после"
        let link = WikilinkParser.parse(text)[0]
        XCTAssertEqual((text as NSString).substring(with: link.range), "[[Ссылка|алиас]]")
    }

    func testEmptyAliasAndHeadingBecomeNil() {
        let links = WikilinkParser.parse("[[Имя|]] [[Имя#]]")
        XCTAssertEqual(links.count, 2)
        XCTAssertNil(links[0].alias)
        XCTAssertNil(links[1].heading)
    }

    // MARK: - ConcealShape (Live Preview сворачивание)

    func testConcealShapePlainLinkHidesOnlyBrackets() {
        let text = "текст [[Заметка]] тут"
        let link = WikilinkParser.parse(text)[0]
        let ns = text as NSString

        XCTAssertEqual(ns.substring(with: link.concealShape.hidePrefix), "[[")
        XCTAssertEqual(ns.substring(with: link.concealShape.hideSuffix), "]]")
        XCTAssertEqual(ns.substring(with: link.concealShape.visible), "Заметка")
    }

    func testConcealShapeAliasedLinkHidesTargetAndPipe() {
        let text = "[[Заметка|алиас]]"
        let link = WikilinkParser.parse(text)[0]
        let ns = text as NSString

        XCTAssertEqual(ns.substring(with: link.concealShape.hidePrefix), "[[Заметка|")
        XCTAssertEqual(ns.substring(with: link.concealShape.hideSuffix), "]]")
        XCTAssertEqual(ns.substring(with: link.concealShape.visible), "алиас")
    }

    func testConcealShapeAliasedWithHeadingHidesPrefixIncludingHash() {
        let text = "[[Заметка#Секция|алиас]]"
        let link = WikilinkParser.parse(text)[0]
        let ns = text as NSString

        XCTAssertEqual(ns.substring(with: link.concealShape.hidePrefix), "[[Заметка#Секция|")
        XCTAssertEqual(ns.substring(with: link.concealShape.visible), "алиас")
    }

    func testConcealShapeHeadingOnlyHidesHashOnward() {
        let text = "[[Заметка#Секция]]"
        let link = WikilinkParser.parse(text)[0]
        let ns = text as NSString

        XCTAssertEqual(ns.substring(with: link.concealShape.hidePrefix), "[[")
        XCTAssertEqual(ns.substring(with: link.concealShape.hideSuffix), "#Секция]]")
        XCTAssertEqual(ns.substring(with: link.concealShape.visible), "Заметка")
    }

    func testConcealShapeTrimsWhitespaceInsideBrackets() {
        let text = "[[ Заметка | алиас ]]"
        let link = WikilinkParser.parse(text)[0]
        let ns = text as NSString

        // Пробелы вокруг alias уходят в hidePrefix/hideSuffix — видимая часть
        // без хвостовых пробелов.
        XCTAssertEqual(ns.substring(with: link.concealShape.visible), "алиас")
        XCTAssertEqual(ns.substring(with: link.concealShape.hidePrefix), "[[ Заметка | ")
        XCTAssertEqual(ns.substring(with: link.concealShape.hideSuffix), " ]]")
    }

    func testConcealShapeRangesCoverWholeMatchExactly() {
        // hidePrefix + visible + hideSuffix должны в сумме давать весь range —
        // никаких пропущенных/перекрывающихся символов.
        for text in ["[[Заметка]]", "[[Заметка|алиас]]", "[[Заметка#Секция]]", "[[Заметка#Секция|алиас]]"] {
            let link = WikilinkParser.parse(text)[0]
            let shape = link.concealShape
            XCTAssertEqual(shape.hidePrefix.location, link.range.location)
            XCTAssertEqual(NSMaxRange(shape.hideSuffix), NSMaxRange(link.range))
            XCTAssertEqual(NSMaxRange(shape.hidePrefix), shape.visible.location)
            XCTAssertEqual(NSMaxRange(shape.visible), shape.hideSuffix.location)
        }
    }

    func testConcealShapeCyrillicAndEmojiRangesValidUTF16() {
        let text = "заметка [[Планы 🚀|цель]] конец"
        let link = WikilinkParser.parse(text)[0]
        let ns = text as NSString
        XCTAssertLessThanOrEqual(NSMaxRange(link.concealShape.hideSuffix), ns.length)
        XCTAssertEqual(ns.substring(with: link.concealShape.visible), "цель")
    }
}

// MARK: - FrontmatterParser

final class FrontmatterParserTests: XCTestCase {

    func testParsesFlatTypes() throws {
        let text = """
        ---
        title: Встреча с командой
        rating: 4.5
        count: 7
        date: 2026-07-07
        tags: [работа, "встречи"]
        people:
          - Аня
          - Борис
        ---
        Тело заметки.
        """
        let doc = FrontmatterParser.parse(text)

        XCTAssertEqual(doc["title"], .string("Встреча с командой"))
        XCTAssertEqual(doc["rating"], .number(4.5))
        XCTAssertEqual(doc["count"], .number(7))
        XCTAssertEqual(doc["date"], .date(FrontmatterParser.dateFormatter.date(from: "2026-07-07")!))
        XCTAssertEqual(doc["tags"], .list(["работа", "встречи"]))
        XCTAssertEqual(doc["people"], .list(["Аня", "Борис"]))
        XCTAssertEqual(doc.body, "Тело заметки.")
    }

    func testNoFrontmatterMeansWholeTextIsBody() {
        let doc = FrontmatterParser.parse("Просто текст без метаданных.")
        XCTAssertTrue(doc.entries.isEmpty)
        XCTAssertEqual(doc.body, "Просто текст без метаданных.")
    }

    func testBrokenFrontmatterDoesNotCrashAndKeepsText() {
        // Нет закрывающего «---» — весь файл считается телом.
        let text = "---\ntitle: без конца\nТело."
        let doc = FrontmatterParser.parse(text)

        XCTAssertTrue(doc.entries.isEmpty)
        XCTAssertEqual(doc.body, text)
    }

    func testUnknownLinesPreservedVerbatim() {
        let text = """
        ---
        title: Заметка
        nested:
          deep: value
        # комментарий
        ---
        Тело.
        """
        let doc = FrontmatterParser.parse(text)

        // nested: — ключ с пустым значением (вложенность не парсим), строка
        // «  deep: value» и комментарий выживают как raw и не теряются.
        XCTAssertEqual(doc.serialized(), text)
    }

    func testRoundTripIsByteExact() {
        let text = """
        ---
        title: Планы 🚀
        tags: [a, b]
        list:
          - раз
          - два
        weird line without colon
        ---
        # Тело

        С **markdown** и [[ссылкой]].
        """
        let doc = FrontmatterParser.parse(text)
        XCTAssertEqual(doc.serialized(), text)
    }

    func testSubscriptSetUpdatesAndSerializes() {
        var doc = FrontmatterParser.parse("---\ntitle: Старое\n---\nТело.")
        doc["title"] = .string("Новое")
        doc["tags"] = .list(["один", "два"])

        let expected = """
        ---
        title: Новое
        tags:
          - один
          - два
        ---
        Тело.
        """
        XCTAssertEqual(doc.serialized(), expected)
    }

    func testEmptyFrontmatterSerializesToBodyOnly() {
        var doc = FrontmatterParser.parse("---\ntitle: x\n---\nТело.")
        doc["title"] = nil
        XCTAssertEqual(doc.serialized(), "Тело.")
    }
}

// MARK: - LinkIndex

final class LinkIndexTests: VaultTestCase {

    private func buildIndex() -> LinkIndex {
        let index = LinkIndex(root: tempDir)
        index.buildFull()
        return index
    }

    func testResolveByNameCaseInsensitive() throws {
        try makeFile("Папка/Целевая заметка.md")
        let index = buildIndex()

        XCTAssertEqual(
            index.resolve("целевая ЗАМЕТКА")?.lastPathComponent,
            "Целевая заметка.md"
        )
        XCTAssertNil(index.resolve("нет такой"))
    }

    func testResolveDuplicatesPrefersShortestPath() throws {
        try makeFile("Заметка.md")
        try makeFile("Глубоко/Вложенно/Заметка.md")
        let index = buildIndex()

        XCTAssertEqual(index.resolve("Заметка"), tempDir.appendingPathComponent("Заметка.md").standardizedFileURL)
    }

    func testResolveByRelativePath() throws {
        try makeFile("Заметка.md")
        try makeFile("Папка/Заметка.md")
        let index = buildIndex()

        XCTAssertEqual(
            index.resolve("Папка/Заметка")?.standardizedFileURL,
            tempDir.appendingPathComponent("Папка/Заметка.md").standardizedFileURL
        )
    }

    func testBacklinksWithSnippets() throws {
        try makeFile("Цель.md", contents: "содержимое")
        try makeFile("Источник 1.md", contents: "строка со ссылкой [[Цель]] тут")
        try makeFile("Папка/Источник 2.md", contents: "первая строка\n[[Цель|алиас]]")
        try makeFile("Мимо.md", contents: "ссылка [[Другая]]")
        let index = buildIndex()

        let backlinks = index.backlinks(to: tempDir.appendingPathComponent("Цель.md"))

        XCTAssertEqual(backlinks.count, 2)
        XCTAssertEqual(
            backlinks.map { $0.sourceFile.lastPathComponent }.sorted(),
            ["Источник 1.md", "Источник 2.md"]
        )
        let first = backlinks.first { $0.sourceFile.lastPathComponent == "Источник 1.md" }!
        XCTAssertEqual(first.snippet, "строка со ссылкой [[Цель]] тут")
        XCTAssertEqual(first.lineNumber, 1)
        let second = backlinks.first { $0.sourceFile.lastPathComponent == "Источник 2.md" }!
        XCTAssertEqual(second.lineNumber, 2)
    }

    func testSelfLinksExcludedFromBacklinks() throws {
        try makeFile("Сам.md", contents: "ссылаюсь на [[Сам]] себя")
        let index = buildIndex()

        XCTAssertTrue(index.backlinks(to: tempDir.appendingPathComponent("Сам.md")).isEmpty)
    }

    func testUpdateFilePicksUpNewLinks() throws {
        let source = try makeFile("Источник.md", contents: "пока без ссылок")
        try makeFile("Цель.md")
        let index = buildIndex()
        XCTAssertTrue(index.backlinks(to: tempDir.appendingPathComponent("Цель.md")).isEmpty)

        try "теперь [[Цель]]".write(to: source, atomically: true, encoding: .utf8)
        index.updateFile(source)

        XCTAssertEqual(index.backlinks(to: tempDir.appendingPathComponent("Цель.md")).count, 1)
    }

    func testRefreshDetectsNewChangedAndRemovedFiles() throws {
        try makeFile("Цель.md")
        let source = try makeFile("Источник.md", contents: "[[Цель]]")
        let index = buildIndex()
        let target = tempDir.appendingPathComponent("Цель.md")
        XCTAssertEqual(index.backlinks(to: target).count, 1)

        // Новый файл со ссылкой + удаление старого источника.
        try makeFile("Новый источник.md", contents: "и снова [[Цель]]")
        try FileManager.default.removeItem(at: source)
        // mtime новых файлов заведомо отличается (создание «сейчас»).
        XCTAssertTrue(index.refresh())

        let backlinks = index.backlinks(to: target)
        XCTAssertEqual(backlinks.map { $0.sourceFile.lastPathComponent }, ["Новый источник.md"])

        // Повторный refresh без изменений — false.
        XCTAssertFalse(index.refresh())
    }

    func testDotFoldersIgnored() throws {
        try makeFile(".obsidian/шаблон.md", contents: "[[Цель]]")
        try makeFile("Цель.md")
        let index = buildIndex()

        XCTAssertTrue(index.backlinks(to: tempDir.appendingPathComponent("Цель.md")).isEmpty)
    }

    func testCompletionTargetsUseShortNamesAndPathsForDuplicates() throws {
        try makeFile("Уникальная.md")
        try makeFile("Дубль.md")
        try makeFile("Папка/Дубль.md")
        let index = buildIndex()

        let targets = index.completionTargets
        XCTAssertTrue(targets.contains("Уникальная"))
        XCTAssertTrue(targets.contains("Дубль"))
        XCTAssertTrue(targets.contains("Папка/Дубль"))
    }
}

// MARK: - NoteRenamePlanner

final class NoteRenamePlannerTests: XCTestCase {

    private let sourceFile = URL(fileURLWithPath: "/vault/Источник.md")

    private func occurrence(_ text: String, index: Int = 0) -> LinkOccurrence {
        let link = WikilinkParser.parse(text)[index]
        return LinkOccurrence(sourceFile: sourceFile, link: link, snippet: text, lineNumber: 1)
    }

    func testPlainTargetIsRenamed() {
        let rewrites = NoteRenamePlanner.rewrites(for: [occurrence("[[Старое]]")], newName: "Новое")
        XCTAssertEqual(rewrites[0].replacement, "[[Новое]]")
    }

    func testAliasIsPreserved() {
        let rewrites = NoteRenamePlanner.rewrites(for: [occurrence("[[Старое|алиас]]")], newName: "Новое")
        XCTAssertEqual(rewrites[0].replacement, "[[Новое|алиас]]")
    }

    func testHeadingIsPreserved() {
        let rewrites = NoteRenamePlanner.rewrites(for: [occurrence("[[Старое#Секция]]")], newName: "Новое")
        XCTAssertEqual(rewrites[0].replacement, "[[Новое#Секция]]")
    }

    func testHeadingAndAliasArePreservedTogether() {
        let rewrites = NoteRenamePlanner.rewrites(for: [occurrence("[[Старое#Секция|алиас]]")], newName: "Новое")
        XCTAssertEqual(rewrites[0].replacement, "[[Новое#Секция|алиас]]")
    }

    func testPathTargetKeepsFolderPrefix() {
        let rewrites = NoteRenamePlanner.rewrites(for: [occurrence("[[Папка/Старое]]")], newName: "Новое")
        XCTAssertEqual(rewrites[0].replacement, "[[Папка/Новое]]")
    }

    func testApplyRewritesMultipleOccurrencesInSameFile() {
        let text = "первая [[Старое]] и вторая [[Старое|алиас]] тут"
        let links = WikilinkParser.parse(text)
        let occurrences = links.map { LinkOccurrence(sourceFile: sourceFile, link: $0, snippet: text, lineNumber: 1) }
        let rewrites = NoteRenamePlanner.rewrites(for: occurrences, newName: "Новое")

        XCTAssertEqual(
            NoteRenamePlanner.apply(rewrites, to: text),
            "первая [[Новое]] и вторая [[Новое|алиас]] тут"
        )
    }

    func testApplyLeavesUnrelatedTextUntouched() {
        XCTAssertEqual(NoteRenamePlanner.apply([], to: "без ссылок"), "без ссылок")
    }

    /// Диапазон закэширован в LinkIndex на момент индексации; файл к моменту
    /// apply() мог измениться (правка в открытом редакторе) — на этот же
    /// диапазон в свежем тексте теперь указывает другая ссылка. Правка должна
    /// быть пропущена, а не применена к чужому месту текста.
    func testApplySkipsRewriteWhenRangeContentDoesNotMatchExpectedTarget() {
        let text = "здесь [[Другое]] осталось как было"
        let link = WikilinkParser.parse(text)[0]
        let stale = LinkRewrite(
            sourceFile: sourceFile,
            range: link.range,
            replacement: "[[Новое]]",
            expectedTarget: "Старое" // индекс помнил другую цель на этом месте
        )
        XCTAssertEqual(NoteRenamePlanner.apply([stale], to: text), text)
    }

    /// Файл стал короче (например, вырезали кусок текста) — старый диапазон
    /// указывает за пределы свежего текста. Ревьюер физически воспроизвёл
    /// краш здесь (NSInvalidArgumentException у NSMutableString.replaceCharacters,
    /// это не Swift Error, try/catch его не ловит) — правка обязана быть
    /// отброшена ДО вызова replaceCharacters, а не приводить к abort().
    func testApplySkipsRewriteWhenRangeOutOfBoundsWithoutCrashing() {
        let originalText = "первая [[Старое]] тут"
        let link = WikilinkParser.parse(originalText)[0]
        let shortText = "тут" // диапазон из originalText сюда уже не помещается
        let stale = LinkRewrite(
            sourceFile: sourceFile,
            range: link.range,
            replacement: "[[Новое]]",
            expectedTarget: link.target
        )
        XCTAssertEqual(NoteRenamePlanner.apply([stale], to: shortText), shortText)
    }

    /// В одном файле — валидное и устаревшее вхождение: валидное применяется,
    /// устаревшее пропускается, остальной текст файла не портится.
    func testApplyAppliesValidAndSkipsStaleInSameFile() {
        let text = "первая [[Старое]] и вторая [[Другое]] тут"
        let links = WikilinkParser.parse(text)
        let valid = LinkRewrite(
            sourceFile: sourceFile, range: links[0].range,
            replacement: "[[Новое]]", expectedTarget: links[0].target
        )
        let stale = LinkRewrite(
            sourceFile: sourceFile, range: links[1].range,
            replacement: "[[ЧтоУгодно]]", expectedTarget: "НеТаЦель"
        )
        XCTAssertEqual(
            NoteRenamePlanner.apply([valid, stale], to: text),
            "первая [[Новое]] и вторая [[Другое]] тут"
        )
    }
}

// MARK: - FuzzyMatch

final class FuzzyMatchTests: XCTestCase {

    private let notes = ["Финансы и активы", "Активные проекты", "Архив", "Семья"]

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(FuzzyMatch.filter("", candidates: notes), notes)
    }

    func testPrefixBeatsSubstring() {
        let result = FuzzyMatch.filter("актив", candidates: notes)
        // «Активные проекты» — префикс, «Финансы и активы» — подстрока.
        XCTAssertEqual(result, ["Активные проекты", "Финансы и активы"])
    }

    func testSubsequenceMatchesAndCaseInsensitive() {
        let result = FuzzyMatch.filter("фна", candidates: notes)
        XCTAssertEqual(result, ["Финансы и активы"]) // ф…н…а по порядку
    }

    func testNoMatchesGivesEmpty() {
        XCTAssertTrue(FuzzyMatch.filter("xyz", candidates: notes).isEmpty)
    }
}
