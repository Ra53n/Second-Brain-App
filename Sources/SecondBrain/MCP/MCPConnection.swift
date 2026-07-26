// MCPConnection.swift — одно живое соединение с MCP-сервером (порт из MA).
//
// Подпроцесс (`/usr/bin/env <command> <args>`) + JSON-RPC по stdio с
// построчным фреймингом: частичный ввод копится в buffer, строки режутся по
// \n (0x0A), каждое исходящее сообщение — JSON + \n. Корреляция ответов по
// int-id через pending-континуации. stderr копится для диагностики ошибок.
//
// Инвариант №2: процесс регистрируется в BackgroundProcessRegistry — серверы
// гарантированно умирают вместе с приложением (SIGTERM → SIGKILL).
//
// Закрытие stdout (процесс умер) срывает все pending-ожидания с
// MCPError.process — падение сервера посреди вызова даёт понятную ошибку,
// повторный connect в менеджере пересоздаёт соединение.

import Foundation

/// Чистое ядро stdio-фрейминга MCPConnection (P1): резка буфера на строки и
/// корреляция ответа с ожидающим continuation — без Process и без actor-состояния.
enum MCPFraming {
    /// Режет буфер по \n, пустые строки пропускает; извлечённое удаляется из buffer.
    static func extractLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }

    /// Резолвит continuation, ждущий ответа с этим id; сообщения без корреляции
    /// (запрос/нотификация сервера, неизвестный id, битый JSON) молча отбрасывает.
    static func resolvePending(_ data: Data, in pending: inout [Int: CheckedContinuation<JSONValue, Error>]) {
        guard let message = try? JSONDecoder().decode(RPCIncoming.self, from: data) else { return }
        guard message.method == nil, let id = message.id?.intValue,
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message.error {
            continuation.resume(throwing: MCPError.rpc(error.code, error.message))
        } else {
            continuation.resume(returning: message.result ?? .null)
        }
    }
}

actor MCPConnection {
    let server: MCPServer
    private let registry: BackgroundProcessRegistry
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var buffer = Data()
    private var stderrText = ""
    private(set) var tools: [MCPToolSpec] = []
    private var running = false

    init(server: MCPServer, registry: BackgroundProcessRegistry = .shared) {
        self.server = server
        self.registry = registry
    }

    var isRunning: Bool { running && (process?.isRunning ?? false) }
    var diagnostics: String { stderrText }

    /// Запускает процесс и читающий цикл (идемпотентно).
    private func start() throws {
        if isRunning { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [server.command] + server.args
        proc.environment = MCPEnv.childEnvironment(server)

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // stdout → поток чанков (AsyncStream сохраняет порядок).
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation = $0 }
        let cont = continuation!
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { cont.finish() } else { cont.yield(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendStderr(text) }
        }
        proc.terminationHandler = { _ in cont.finish() }

        try proc.run()
        registry.register(proc) // гарантированное гашение при выходе приложения
        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        running = true
        readTask = Task { [weak self] in await self?.consume(stream) }
    }

    private func appendStderr(_ text: String) {
        stderrText += text
        if stderrText.count > 8000 { stderrText = String(stderrText.suffix(8000)) }
    }

    private func consume(_ stream: AsyncStream<Data>) async {
        for await chunk in stream {
            buffer.append(chunk)
            drainLines()
        }
        // Поток закрылся — процесс завершился. Срываем все ожидания.
        running = false
        let error = MCPError.process(stderrText.isEmpty
                                     ? "процесс завершился"
                                     : String(stderrText.suffix(400)))
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
    }

    /// Буферизация частичных строк: режем по \n, пустые пропускаем.
    private func drainLines() {
        for line in MCPFraming.extractLines(from: &buffer) {
            MCPFraming.resolvePending(line, in: &pending)
        }
    }

    private func request(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
        guard running else { throw MCPError.notConnected }
        let id = nextID
        nextID += 1
        let payload = try JSONEncoder().encode(RPCRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                var line = payload
                line.append(0x0A)
                try stdinHandle?.write(contentsOf: line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String, _ params: JSONValue?) throws {
        var payload = try JSONEncoder().encode(RPCNotification(method: method, params: params))
        payload.append(0x0A)
        try stdinHandle?.write(contentsOf: payload)
    }

    /// initialize → notifications/initialized → tools/list (с пагинацией).
    func handshakeAndListTools() async throws -> [MCPToolSpec] {
        try start()
        let initParams: JSONValue = .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object(["tools": .object([:])]),
            "clientInfo": .object(["name": .string("SecondBrain"), "version": .string("1.0.0")]),
        ])
        _ = try await request("initialize", initParams)
        try notify("notifications/initialized", nil)

        var collected: [MCPToolSpec] = []
        var cursor: String?
        repeat {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await request("tools/list", params)
            if let array = result["tools"]?.arrayValue {
                for tool in array {
                    guard let name = tool["name"]?.stringValue else { continue }
                    collected.append(MCPToolSpec(
                        name: name,
                        description: tool["description"]?.stringValue ?? "",
                        inputSchema: tool["inputSchema"] ?? .object([:])))
                }
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil
        tools = collected
        return collected
    }

    /// Вызов инструмента: склейка текстовых частей result.content;
    /// isError сервера → префикс ERROR (цикл tool-use покажет модели).
    func callTool(_ name: String, arguments: JSONValue) async throws -> String {
        let params: JSONValue = .object(["name": .string(name), "arguments": arguments])
        let result = try await request("tools/call", params)
        var text = ""
        if let content = result["content"]?.arrayValue {
            for part in content {
                if let t = part["text"]?.stringValue { text += t }
            }
        }
        if text.isEmpty { text = result.jsonString }
        if result["isError"]?.boolValue == true { text = "ERROR: " + text }
        return text
    }

    func shutdown() {
        readTask?.cancel()
        readTask = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        running = false
        for (_, continuation) in pending { continuation.resume(throwing: MCPError.notConnected) }
        pending.removeAll()
    }
}
