// MCPConnectionTests.swift — задача 72: чистое ядро stdio-фрейминга
// MCPConnection (MCPFraming) без реального Process/subprocess — резка буфера
// на строки и корреляция ответа с pending-continuation по id.

import XCTest
@testable import SecondBrain

final class MCPConnectionTests: XCTestCase {

    // MARK: - extractLines

    func testExtractLinesPartialMessageInOneRead() {
        // Чанк без \n на конце — сообщение ещё не собрано, ничего не извлекаем.
        var buffer = Data(#"{"jsonrpc":"2.0","id":1,"result"#.utf8)
        let lines = MCPFraming.extractLines(from: &buffer)
        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(buffer.isEmpty)
    }

    func testExtractLinesSplitAcrossTwoReads() {
        var buffer = Data(#"{"jsonrpc":"2.0","id":1,"#.utf8)
        XCTAssertTrue(MCPFraming.extractLines(from: &buffer).isEmpty)

        buffer.append(Data(#""result":{}}"#.utf8))
        buffer.append(0x0A)
        let lines = MCPFraming.extractLines(from: &buffer)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8),
                        #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testExtractLinesSkipsEmptyLines() {
        var buffer = Data("\n\n".utf8)
        buffer.append(Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8))
        buffer.append(0x0A)
        let lines = MCPFraming.extractLines(from: &buffer)
        XCTAssertEqual(lines.count, 1)
    }

    func testExtractLinesBrokenStreamMidJSON() {
        // Обрыв процесса посреди JSON: \n так и не пришёл, строка остаётся
        // в buffer недособранной — не извлекается и не теряется молча как "линия".
        var buffer = Data(#"{"jsonrpc":"2.0","id":3,"resu"#.utf8)
        let lines = MCPFraming.extractLines(from: &buffer)
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(buffer, Data(#"{"jsonrpc":"2.0","id":3,"resu"#.utf8))
    }

    // MARK: - resolvePending

    func testResolvePendingUnknownIdIgnored() {
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        let message = Data(#"{"jsonrpc":"2.0","id":99,"result":{}}"#.utf8)
        // Ни одной continuation в pending — resolvePending не должен падать.
        MCPFraming.resolvePending(message, in: &pending)
        XCTAssertTrue(pending.isEmpty)
    }

    func testResolvePendingHappyPathResolvesContinuation() async throws {
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            pending[7] = continuation
            let message = Data(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#.utf8)
            MCPFraming.resolvePending(message, in: &pending)
        }
        XCTAssertEqual(value["ok"]?.boolValue, true)
        XCTAssertTrue(pending.isEmpty)
    }

    func testResolvePendingErrorPathThrowsRpcError() async {
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[9] = continuation
                let message = Data(#"{"jsonrpc":"2.0","id":9,"error":{"code":-32000,"message":"boom"}}"#.utf8)
                MCPFraming.resolvePending(message, in: &pending)
            }
            XCTFail("должно бросить MCPError.rpc")
        } catch let error as MCPError {
            guard case .rpc(let code, let message) = error else {
                XCTFail("не тот кейс ошибки: \(error)")
                return
            }
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "boom")
        } catch {
            XCTFail("не тот тип ошибки: \(error)")
        }
        XCTAssertTrue(pending.isEmpty)
    }
}
