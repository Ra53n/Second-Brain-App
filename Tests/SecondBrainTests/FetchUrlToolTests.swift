// FetchUrlToolTests.swift — тесты инструмента fetch_url (задача 102).
//
// Транспорт инжектируется — сети нет: успех, отказ по scheme (без сетевого
// вызова), кап 64 КБ, бинарник по NUL, ошибка транспорта, битый аргумент.

import XCTest
@testable import SecondBrain

final class FetchUrlToolTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp")

    private func context(url: String?) -> ToolContext {
        let arguments: JSONValue = url.map { .object(["url": .string($0)]) } ?? .object([:])
        return ToolContext(repoRoot: root, arguments: arguments)
    }

    func testSuccessReturnsBodyText() async {
        var tool = FetchUrlTool()
        let html = "<html><body>Текущая версия: 1.4.2</body></html>"
        tool.perform = { request in
            (Data(html.utf8), URLResponse(url: request.url!, mimeType: "text/html",
                                          expectedContentLength: html.utf8.count,
                                          textEncodingName: "utf-8"))
        }
        let result = await tool.execute(context(url: "https://example.com/status"))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("1.4.2"), result.text)
    }

    func testNonHTTPSchemeRejectedWithoutCallingTransport() async {
        for url in ["file:///etc/passwd", "ftp://example.com/file"] {
            var called = false
            var tool = FetchUrlTool()
            tool.perform = { request in
                called = true
                return (Data(), URLResponse(url: request.url!, mimeType: nil,
                                            expectedContentLength: 0, textEncodingName: nil))
            }
            let result = await tool.execute(context(url: url))
            XCTAssertTrue(result.isError, url)
            XCTAssertFalse(called, url)
        }
    }

    func testBodyOverCapIsTruncatedWithMarker() async {
        var tool = FetchUrlTool()
        let big = Data(repeating: 0x41, count: FetchUrlTool.maxBytes + 1024)
        tool.perform = { request in
            (big, URLResponse(url: request.url!, mimeType: "text/plain",
                              expectedContentLength: big.count, textEncodingName: "utf-8"))
        }
        let result = await tool.execute(context(url: "https://example.com/big"))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("обрезан"), result.text)
        XCTAssertLessThan(result.text.utf8.count, big.count)
    }

    func testBinaryResponseRejected() async {
        var tool = FetchUrlTool()
        let binary = Data([0x41, 0x00, 0x42])
        tool.perform = { request in
            (binary, URLResponse(url: request.url!, mimeType: "application/octet-stream",
                                 expectedContentLength: binary.count, textEncodingName: nil))
        }
        let result = await tool.execute(context(url: "https://example.com/bin"))
        XCTAssertTrue(result.isError)
    }

    func testTransportErrorReturnsErrorNotCrash() async {
        var tool = FetchUrlTool()
        tool.perform = { _ in throw URLError(.notConnectedToInternet) }
        let result = await tool.execute(context(url: "https://example.com/down"))
        XCTAssertTrue(result.isError)
    }

    func testMissingOrEmptyURLArgumentIsError() async {
        var called = false
        var tool = FetchUrlTool()
        tool.perform = { request in
            called = true
            return (Data(), URLResponse(url: request.url!, mimeType: nil,
                                        expectedContentLength: 0, textEncodingName: nil))
        }
        let missing = await tool.execute(context(url: nil))
        XCTAssertTrue(missing.isError)
        let empty = await tool.execute(context(url: ""))
        XCTAssertTrue(empty.isError)
        let malformed = await tool.execute(context(url: "не url"))
        XCTAssertTrue(malformed.isError)
        XCTAssertFalse(called)
    }
}
