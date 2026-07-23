// LinkRewriterTests.swift — тесты чистого ядра переписывания [[ссылок]] (задача 54).
//
// Покрытие: все формы ссылки (bare/alias/heading/path/вложенный путь), кириллица и
// эмодзи в UTF-16, регистронезависимый отбор целей, сохранение алиаса/заголовка/пути/
// пробелов, игнор код-блоков и инлайн-кода, дубли имён (правится только совпавшая
// цель), несколько ссылок в одном тексте (порядок замен справа налево), no-op на
// пустом oldTargets и на тексте без ссылок, многострочный текст.

import XCTest
@testable import SecondBrain

final class LinkRewriterTests: XCTestCase {

    /// Таблица простых случаев «одна ссылка в тексте» — форма конструкции и как она
    /// должна выглядеть после переименования Old → New. `oldTargets` — точная строка
    /// target (регистронезависимо), как её собрал бы backlinks(to:): для bare-ссылки
    /// это просто имя, для path-ссылки — имя ВМЕСТЕ с папкой (так резолвится путь).
    func testSingleLinkForms() {
        let cases: [(text: String, oldTargets: Set<String>, expected: String, name: String)] = [
            ("[[Old]]", ["old"], "[[New]]", "bare"),
            ("[[Old|подпись]]", ["old"], "[[New|подпись]]", "alias цел"),
            ("[[Old#Раздел]]", ["old"], "[[New#Раздел]]", "заголовок цел"),
            ("[[Old#Раздел|подпись]]", ["old"], "[[New#Раздел|подпись]]", "alias+заголовок целы"),
            ("[[папка/Old]]", ["папка/old"], "[[папка/New]]", "папка-префикс цел"),
            ("[[a/b/Old]]", ["a/b/old"], "[[a/b/New]]", "вложенный путь цел"),
        ]
        for c in cases {
            let result = LinkRewriter.rewrite(in: c.text, oldTargets: c.oldTargets, newBaseName: "New")
            XCTAssertEqual(result, c.expected, c.name)
        }
    }

    func testCyrillicNamesAndPaths() {
        let bare = LinkRewriter.rewrite(
            in: "смотри [[Заметка]] тут",
            oldTargets: ["заметка"],
            newBaseName: "Другое имя"
        )
        XCTAssertEqual(bare, "смотри [[Другое имя]] тут")

        let path = LinkRewriter.rewrite(
            in: "[[Проекты/Старая]] и текст",
            oldTargets: ["проекты/старая"],
            newBaseName: "Новая"
        )
        XCTAssertEqual(path, "[[Проекты/Новая]] и текст")
    }

    /// Эмодзи — суррогатная пара в UTF-16: срез последнего компонента после «/» и
    /// сама замена не должны разрывать её (иначе — крэш или мусор на границе).
    func testEmojiInTargetAndReplacementSurviveUTF16Slicing() {
        let text = "план [[Проекты/Заметка 🚀]] и [[Проекты/Заметка 🚀|псевдоним]] тут"
        let result = LinkRewriter.rewrite(
            in: text,
            oldTargets: ["проекты/заметка 🚀"],
            newBaseName: "Новая 🎉"
        )
        XCTAssertEqual(result, "план [[Проекты/Новая 🎉]] и [[Проекты/Новая 🎉|псевдоним]] тут")
    }

    /// Регистр итоговой цели берётся из newBaseName, а сопоставление с oldTargets —
    /// регистронезависимое (набор целей приходит из backlinks уже lowercased).
    func testMatchingIsCaseInsensitiveResultCaseComesFromNewName() {
        for original in ["[[Old]]", "[[OLD]]", "[[oLd]]"] {
            let result = LinkRewriter.rewrite(in: original, oldTargets: ["old"], newBaseName: "New")
            XCTAssertEqual(result, "[[New]]", original)
        }
    }

    func testLinksInsideCodeAreNotTouched() {
        let text = """
        [[Old]] настоящая ссылка
        `[[Old]]` в инлайн-коде
        ```
        [[Old]] в код-блоке
        ```
        """
        let expected = """
        [[New]] настоящая ссылка
        `[[Old]]` в инлайн-коде
        ```
        [[Old]] в код-блоке
        ```
        """
        XCTAssertEqual(LinkRewriter.rewrite(in: text, oldTargets: ["old"], newBaseName: "New"), expected)
    }

    /// Дубли имён: правится только та цель, что реально попала в oldTargets (её
    /// собрал бы backlinks(to:) для конкретного переименовываемого файла) — bare-имя
    /// и путь резолвятся в разные файлы, поэтому набор целей у них разный.
    func testOnlyMatchingTargetAmongDuplicatesIsRewritten() {
        let text = "видел [[Old]] и ещё [[Архив/Old]] тоже"

        // Переименовываем bare-победителя — путь-однофамилец не тронут.
        let bareRenamed = LinkRewriter.rewrite(in: text, oldTargets: ["old"], newBaseName: "New")
        XCTAssertEqual(bareRenamed, "видел [[New]] и ещё [[Архив/Old]] тоже")

        // И наоборот: переименовываем Архив/Old — bare-ссылка на другой файл цела.
        let pathRenamed = LinkRewriter.rewrite(in: text, oldTargets: ["архив/old"], newBaseName: "New")
        XCTAssertEqual(pathRenamed, "видел [[Old]] и ещё [[Архив/New]] тоже")
    }

    /// Похожее, но НЕ совпадающее имя («Oldest» ⊅ «Old») не должно зацепиться —
    /// отбор точным равенством, а не префиксом/подстрокой.
    func testNearMissTargetIsNotRewritten() {
        let result = LinkRewriter.rewrite(in: "[[Oldest]]", oldTargets: ["old"], newBaseName: "New")
        XCTAssertEqual(result, "[[Oldest]]")
    }

    /// Несколько ссылок в одном тексте, включая разной длины и на разных строках —
    /// правая замена (замена целей разной длины) не должна съедать соседние диапазоны.
    func testMultipleLinksOnSameAndDifferentLinesAllRewrittenWithoutRangeDrift() {
        let text = """
        первая [[Old]] и [[Old|подпись подлиннее]]
        вторая строка [[папка/Old#Раздел]]
        третья [[Old]]
        """
        let expected = """
        первая [[New]] и [[New|подпись подлиннее]]
        вторая строка [[папка/New#Раздел]]
        третья [[New]]
        """
        XCTAssertEqual(LinkRewriter.rewrite(in: text, oldTargets: ["old", "папка/old"], newBaseName: "New"), expected)
    }

    /// Замена на явно более короткое и более длинное имя — тоже не должна сдвинуть
    /// соседние вхождения (регрессия на сортировку «справа налево»).
    func testReplacementLengthChangeDoesNotShiftOtherOccurrences() {
        let text = "[[Old]] [[Old]] [[Old]]"
        XCTAssertEqual(
            LinkRewriter.rewrite(in: text, oldTargets: ["old"], newBaseName: "X"),
            "[[X]] [[X]] [[X]]"
        )
        XCTAssertEqual(
            LinkRewriter.rewrite(in: text, oldTargets: ["old"], newBaseName: "Значительно более длинное имя"),
            "[[Значительно более длинное имя]] [[Значительно более длинное имя]] [[Значительно более длинное имя]]"
        )
    }

    func testEmptyOldTargetsIsNoOp() {
        let text = "[[Old]] и [[Другое]] тут"
        XCTAssertEqual(LinkRewriter.rewrite(in: text, oldTargets: [], newBaseName: "New"), text)
    }

    func testTextWithoutLinksIsUnchanged() {
        let text = "просто текст без ссылок вообще"
        XCTAssertEqual(LinkRewriter.rewrite(in: text, oldTargets: ["old"], newBaseName: "New"), text)
    }

    /// Пробелы внутри скобок — часть исходного форматирования, не трогаем их;
    /// заменяется только сам сегмент цели (targetRange уже триммирован парсером).
    func testWhitespaceInsideBracketsIsPreserved() {
        let result = LinkRewriter.rewrite(in: "[[ Old ]]", oldTargets: ["old"], newBaseName: "New")
        XCTAssertEqual(result, "[[ New ]]")
    }

    func testMultilineTextWithLinkNotOnFirstLine() {
        let text = """
        Заголовок заметки

        Первый абзац без ссылок.

        Второй абзац с [[Old]] внутри.

        Третий абзац.
        """
        let expected = """
        Заголовок заметки

        Первый абзац без ссылок.

        Второй абзац с [[New]] внутри.

        Третий абзац.
        """
        XCTAssertEqual(LinkRewriter.rewrite(in: text, oldTargets: ["old"], newBaseName: "New"), expected)
    }
}
