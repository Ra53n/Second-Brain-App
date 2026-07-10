// IncrementalHighlightTests.swift — инвариант инкрементальной подсветки:
// пересобранный кэш маркеров РАВЕН полному парсу нового текста.
//
// Это сердце оптимизации: highlightIncrementally перепарсивает только блок и
// сдвигает остальные маркеры на изменение длины. Если результат разойдётся с
// полным парсом — сокрытие/проявление рассинхронизируется. Здесь симулируем
// правки и сверяем rebuiltConcealables/rebuiltLinks с эталонным полным парсом.
// Корпус — без ``` и %% (структурные правки идут в полный проход, не сюда).

import XCTest
@testable import SecondBrain

final class IncrementalHighlightTests: XCTestCase {

    // MARK: - Хелперы: воспроизводят разбор styleRegion (маркеры/ссылки)

    /// Полный парс маркеров (как styleRegion includeMultiBlock: true).
    private func fullMarkers(_ text: String) -> [ConcealableMarker] {
        let ns = text as NSString
        var m: [ConcealableMarker] = []
        m += BlockReferenceParser.parse(text).map(ConcealableMarker.forBlockReference)
        m += CommentBlockParser.parse(text).map { ConcealableMarker.forCommentBlock($0, in: ns) }
        m += WikilinkParser.parse(text).map(ConcealableMarker.forWikilink)
        m += MarkdownHighlighter.matches(in: text).flatMap { ConcealableMarker.forHighlighterMatch($0, in: ns) }
        m += ConcealableMarker.forListMarkers(in: text)
        return m
    }

    /// Парс маркеров блока (как styleRegion includeMultiBlock: false), сдвинутый
    /// в абсолютные координаты.
    private func blockMarkers(_ text: String, block: NSRange) -> [ConcealableMarker] {
        let ns = text as NSString
        let blockText = ns.substring(with: block)
        let blockNS = blockText as NSString
        var m: [ConcealableMarker] = []
        m += BlockReferenceParser.parse(blockText).map(ConcealableMarker.forBlockReference)
        m += WikilinkParser.parse(blockText).map(ConcealableMarker.forWikilink)
        m += MarkdownHighlighter.matches(in: blockText).flatMap { ConcealableMarker.forHighlighterMatch($0, in: blockNS) }
        m += ConcealableMarker.forListMarkers(in: blockText)
        return m.map { $0.shifted(by: block.location) }
    }

    private func fullLinks(_ text: String) -> [Wikilink] { WikilinkParser.parse(text) }
    private func blockLinks(_ text: String, block: NSRange) -> [Wikilink] {
        let ns = text as NSString
        return WikilinkParser.parse(ns.substring(with: block)).map { shiftLink($0, by: block.location) }
    }
    private func shiftLink(_ l: Wikilink, by d: Int) -> Wikilink {
        func s(_ r: NSRange) -> NSRange { NSRange(location: r.location + d, length: r.length) }
        return Wikilink(range: s(l.range), target: l.target, heading: l.heading, alias: l.alias,
                        concealShape: .init(hidePrefix: s(l.concealShape.hidePrefix), hideSuffix: s(l.concealShape.hideSuffix), visible: s(l.concealShape.visible)))
    }

    /// Каноничный ключ маркера — тотальный порядок для сравнения множеств.
    private func key(_ m: ConcealableMarker) -> String {
        let hides = m.hideRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
        return "\(m.revealTrigger.location):\(m.revealTrigger.length)|\(hides)|\(m.revealStyle)"
    }

    /// Проверяет инвариант: инкрементальная пересборка == полный парс нового текста.
    private func assertEquivalent(old: String, editLocation: Int, deleteLength: Int, insert: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let oldNS = old as NSString
        let newNS = NSMutableString(string: old)
        newNS.replaceCharacters(in: NSRange(location: editLocation, length: deleteLength), with: insert)
        let newText = newNS as String
        let delta = (insert as NSString).length - deleteLength
        let editedRange = NSRange(location: editLocation, length: (insert as NSString).length)

        let ns = newText as NSString
        let newBlock = BlockRange.enclosingBlock(of: editedRange, in: ns)
        let oldBlock = NSRange(location: newBlock.location, length: max(0, newBlock.length - delta))

        let rebuilt = MarkdownEditorView.Coordinator.rebuiltConcealables(
            previous: fullMarkers(old), oldDirty: oldBlock, delta: delta, fresh: blockMarkers(newText, block: newBlock)
        )
        let expected = fullMarkers(newText)
        XCTAssertEqual(rebuilt.map(key).sorted(), expected.map(key).sorted(),
                       "маркеры разошлись; old=\(oldNS) new=\(ns)", file: file, line: line)

        let rebuiltLinks = MarkdownEditorView.Coordinator.rebuiltLinks(
            previous: fullLinks(old), oldDirty: oldBlock, delta: delta, fresh: blockLinks(newText, block: newBlock)
        )
        let expectedLinks = fullLinks(newText).sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(rebuiltLinks, expectedLinks, "ссылки разошлись", file: file, line: line)
    }

    // MARK: - Сценарии правок

    func testInsertPlainCharInBody() {
        assertEquivalent(old: "# Заголовок\n\nтекст [[Ссылка]] тут\n\n- пункт", editLocation: 16, deleteLength: 0, insert: "Х")
    }

    func testTypingSecondAsteriskCompletesBold() {
        // "*жирный*" → "**жирный*" (курсор дописывает второй *, bold ещё не полон),
        // затем полный "**жирный**".
        assertEquivalent(old: "текст *жирный* конец\n\nвторой абзац [[Л]]", editLocation: 6, deleteLength: 0, insert: "*")
        assertEquivalent(old: "текст **жирный* конец", editLocation: 14, deleteLength: 0, insert: "*")
    }

    func testDeleteBreaksWikilink() {
        // Удаляем «]» из «[[Заметка]]» — ссылка ломается, маркеры должны исчезнуть.
        let text = "перед [[Заметка]] после\n\nхвост"
        let closeBracket = (text as NSString).range(of: "]]").location
        assertEquivalent(old: text, editLocation: closeBracket, deleteLength: 1, insert: "")
    }

    func testInsertListMarker() {
        assertEquivalent(old: "заголовок\n\nобычный текст\n\nещё", editLocation: 11, deleteLength: 0, insert: "- ")
    }

    func testInsertHeadingHash() {
        assertEquivalent(old: "текст один\n\nтекст два [[Л]]\n\nтекст три", editLocation: 12, deleteLength: 0, insert: "# ")
    }

    func testInsertNewParagraphAtEnd() {
        assertEquivalent(old: "# Раз\n\n**два**", editLocation: 13, deleteLength: 0, insert: "\n\n- три [[Ссылка|али]]")
    }

    func testDeleteAcrossParagraphMerge() {
        // Удаляем пустую строку-разделитель — два абзаца сливаются.
        let text = "первый [[A]]\n\nвторой **B**"
        let sep = (text as NSString).range(of: "\n\n").location
        assertEquivalent(old: text, editLocation: sep, deleteLength: 2, insert: "\n")
    }

    // MARK: - Точечные проверки shifted / rebuilt

    func testMarkerShiftedMovesAllRanges() {
        let m = ConcealableMarker(hideRanges: [NSRange(location: 2, length: 2), NSRange(location: 10, length: 2)],
                                  revealTrigger: NSRange(location: 0, length: 15), revealStyle: .plain)
        let s = m.shifted(by: 100)
        XCTAssertEqual(s.hideRanges, [NSRange(location: 102, length: 2), NSRange(location: 110, length: 2)])
        XCTAssertEqual(s.revealTrigger, NSRange(location: 100, length: 15))
        XCTAssertEqual(s.revealStyle, .plain)
        XCTAssertEqual(m.shifted(by: 0), m)
    }

    func testRebuiltKeepsBeforeShiftsAfterDropsInside() {
        let before = ConcealableMarker(hideRanges: [NSRange(location: 0, length: 1)], revealTrigger: NSRange(location: 0, length: 5), revealStyle: .plain)
        let inside = ConcealableMarker(hideRanges: [NSRange(location: 6, length: 1)], revealTrigger: NSRange(location: 6, length: 5), revealStyle: .plain)
        let after = ConcealableMarker(hideRanges: [NSRange(location: 20, length: 1)], revealTrigger: NSRange(location: 20, length: 5), revealStyle: .plain)
        let fresh = ConcealableMarker(hideRanges: [NSRange(location: 7, length: 2)], revealTrigger: NSRange(location: 6, length: 8), revealStyle: .plain)
        // Грязный блок [6,12); delta +3 (после блока сдвигается на 3).
        let result = MarkdownEditorView.Coordinator.rebuiltConcealables(
            previous: [before, inside, after], oldDirty: NSRange(location: 6, length: 6), delta: 3, fresh: [fresh]
        )
        XCTAssertTrue(result.contains(before))              // до правки — без изменений
        XCTAssertFalse(result.contains(inside))             // внутри — выброшен
        XCTAssertTrue(result.contains(fresh))               // свежий — добавлен
        XCTAssertTrue(result.contains(after.shifted(by: 3))) // после — сдвинут
    }
}
