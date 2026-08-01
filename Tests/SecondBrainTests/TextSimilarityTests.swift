// TextSimilarityTests.swift — задача 85: эталоны из реального
// `python3 -c "from difflib import SequenceMatcher; ..."` (autojunk python по умолчанию,
// isjunk=None). Длинные кейсы — реальная склейка нормализованных `task` из
// finetune/meetings/data/valid.jsonl (индексы 28/30/73/75), где autojunk включается.

import XCTest
@testable import SecondBrain

final class TextSimilarityTests: XCTestCase {
    private let epsilon = 1e-9

    func testEmptyBothIsOne() {
        XCTAssertEqual(TextSimilarity.ratio("", ""), 1.0, accuracy: epsilon)
    }

    func testEmptyAgainstNonEmptyIsZero() {
        XCTAssertEqual(TextSimilarity.ratio("", "a"), 0.0, accuracy: epsilon)
    }

    func testIdenticalSingleCharIsOne() {
        XCTAssertEqual(TextSimilarity.ratio("a", "a"), 1.0, accuracy: epsilon)
    }

    func testKittenSitting() {
        XCTAssertEqual(TextSimilarity.ratio("kitten", "sitting"), 0.6153846153846154, accuracy: epsilon)
    }

    func testCyrillicYoVsYe() {
        XCTAssertEqual(TextSimilarity.ratio("подготовить отчёт", "подготовить отчет"),
                       0.9411764705882353, accuracy: epsilon)
    }

    func testTaskPhraseWithExtraWord() {
        XCTAssertEqual(TextSimilarity.ratio("собрать команду и обсудить план", "собрать команду обсудить план"),
                       0.9666666666666667, accuracy: epsilon)
    }

    func testTaskPhrasePartiallyDifferentVerb() {
        XCTAssertEqual(TextSimilarity.ratio("купить билеты на завтра", "заказать билеты на завтра"),
                       0.8333333333333334, accuracy: epsilon)
    }

    func testTaskPhraseMostlyDifferent() {
        XCTAssertEqual(TextSimilarity.ratio("проверить дедлайн по задаче", "уточнить срок по задаче"),
                       0.6, accuracy: epsilon)
    }

    func testCompletelyDifferentTasks() {
        XCTAssertEqual(TextSimilarity.ratio("купить кофе", "подготовить квартальный отчёт по продажам"),
                       0.2692307692307692, accuracy: epsilon)
    }

    func testSymmetric() {
        let a = "собрать команду и обсудить план"
        let b = "заказать билеты на завтра"
        XCTAssertEqual(TextSimilarity.ratio(a, b), TextSimilarity.ratio(b, a), accuracy: epsilon)
    }

    // MARK: - autojunk (длинные склейки task из finetune/meetings/data/valid.jsonl)

    // Пример 75 (341 симв.): "иметь тридцать минут после обеда..." трижды подряд + хвост.
    private let longTask75 = "иметь тридцать минут после обеда для работы над своими индивидуальными "
        + "презентациями иметь тридцать минут после обеда для работы над своими индивидуальными "
        + "презентациями иметь тридцать минут после обеда для работы над своими индивидуальными "
        + "презентациями оформить протокол и положить протоколы и этого, и предыдущего собрания в папку проекта"

    // Пример 28 (283 симв.): "создать прототип..." дважды подряд.
    private let longTask28 = "создать прототип; дизайнер интерфейса решит, какие кнопки будут включены, "
        + "а промышленный дизайнер сосредоточится на внешнем виде и материалах "
        + "создать прототип; дизайнер интерфейса решит, какие кнопки будут включены, "
        + "а промышленный дизайнер сосредоточится на внешнем виде и материалах"

    // Пример 30 (312 симв.): короткая приписка + тот же дублированный текст, что и 28.
    private let longTask30 = "подготовить оценку прототипа " + "создать прототип; дизайнер интерфейса решит, "
        + "какие кнопки будут включены, а промышленный дизайнер сосредоточится на внешнем виде и материалах "
        + "создать прототип; дизайнер интерфейса решит, какие кнопки будут включены, "
        + "а промышленный дизайнер сосредоточится на внешнем виде и материалах"

    // Пример 73/69/71 (203 симв., идентичны): "работать вместе над прототипом..." дважды.
    private let longTask73 = "работать вместе над прототипом, используя smart-доску. маркетолог будет "
        + "работать над оценкой продукта работать вместе над прототипом, используя smart-доску. "
        + "маркетолог будет работать над оценкой продукта"

    func testLongFixturesHaveExpectedLength() {
        XCTAssertEqual(longTask75.count, 341)
        XCTAssertEqual(longTask28.count, 283)
        XCTAssertEqual(longTask30.count, 312)
        XCTAssertEqual(longTask73.count, 203)
    }

    /// Без autojunk (наивный Ratcliff/Obershelp) для этой пары python даёт 0.15064102564102563
    /// — популярные слоги «иметь», «после», «работы» и т.п. инфлируют совпадение мимо семантики.
    func testAutojunkAppliesOnLongDuplicatedPhrase() {
        XCTAssertEqual(TextSimilarity.ratio(longTask75, longTask28), 0.03205128205128205, accuracy: epsilon)
    }

    func testAutojunkAppliesLen75vs30() {
        XCTAssertEqual(TextSimilarity.ratio(longTask75, longTask30), 0.039816232771822356, accuracy: epsilon)
    }

    func testAutojunkAppliesLen73vs75() {
        XCTAssertEqual(TextSimilarity.ratio(longTask73, longTask75), 0.022058823529411766, accuracy: epsilon)
    }

    /// Обе строки ≥ 200 символов, но популярные символы не совпадают по позициям настолько,
    /// чтобы пруннинг что-то менял — контрольный случай «autojunk есть, а разницы с
    /// наивным алгоритмом нет» (28/30 совпадают и с `autojunk=False`).
    func testAutojunkNoOpWhenPopularCharsDoNotAffectAlignment() {
        XCTAssertEqual(TextSimilarity.ratio(longTask28, longTask30), 0.9512605042016806, accuracy: epsilon)
    }

    func testIdenticalLongStringsStillOne() {
        XCTAssertEqual(TextSimilarity.ratio(longTask73, longTask73), 1.0, accuracy: epsilon)
    }

    // MARK: - autojunk: граница len(b) == 200

    /// Синтетическая пара: b — одиночные разбросанные 'о' (частый символ) среди разных
    /// согласных, a — только 'о'. При len(b) < 200 autojunk не активируется (наивный
    /// алгоритм = python); ровно на 200 включается и резко меняет ratio (эталоны — реальный
    /// python: `SequenceMatcher(None, a, b).ratio()` для n=199 и n=200 через этот генератор).
    private func popularScatter(_ n: Int, every: Int = 5) -> String {
        var chars: [Character] = []
        for i in 0..<n {
            if i % every == 0 {
                chars.append("о")
            } else {
                let scalar = Unicode.Scalar(0x0431 + (i % 25))!
                chars.append(Character(scalar))
            }
        }
        return String(chars)
    }

    func testAutojunkBoundaryBelow200MatchesNaive() {
        let n = 199
        let b = popularScatter(n)
        let a = String(repeating: "о", count: n / 5 + 1)
        XCTAssertEqual(TextSimilarity.ratio(a, b), 0.33472803347280333, accuracy: epsilon)
    }

    func testAutojunkBoundaryAt200DivergesSharply() {
        let n = 200
        let b = popularScatter(n)
        let a = String(repeating: "о", count: n / 5 + 1)
        XCTAssertEqual(TextSimilarity.ratio(a, b), 0.008298755186721992, accuracy: epsilon)
    }
}
