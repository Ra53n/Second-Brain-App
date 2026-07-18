// RunCommandTool.swift — запуск shell-команд из чата (задача 39).
//
// Команда исполняется /bin/zsh -c в корне проекта чата; PATH дополняется
// типовыми каталогами (MCPEnv.augmentedPATH — GUI-.app из Finder получает
// голый PATH без homebrew/nvm). Разрешение даёт слой ToolPermissions:
// безопасный список (swift build/test, git-обзор) — safe, всё остальное —
// dangerous и требует approve (гейт в ChatToolAssembly).
//
// Инвариант №2 (ARCHITECTURE.md): процесс регистрируется в
// BackgroundProcessRegistry — при выходе приложения не осиротеет. Таймаут
// гасит процесс SIGTERM → SIGKILL.

import Foundation

/// @unchecked Sendable: реестр процессов сам сериализует доступ (NSLock).
final class RunCommandTool: BuiltinTool, @unchecked Sendable {
    static let defaultTimeoutSeconds = 120
    static let maxTimeoutSeconds = 600
    /// Кап суммарного вывода (stdout+stderr) — модели больше не нужно.
    static let maxOutputChars = 32 * 1024

    let name = "run_command"
    let description = "Выполнить shell-команду в корне проекта (сборка, тесты, git). Опасные команды требуют подтверждения пользователя."
    let parameters = ToolSchemas.object([
        "command": ToolSchemas.string("Команда shell (zsh). Например: swift test"),
        "timeoutSeconds": ToolSchemas.integer("Таймаут в секундах (по умолчанию \(RunCommandTool.defaultTimeoutSeconds), максимум \(RunCommandTool.maxTimeoutSeconds)).")
    ], required: ["command"])

    /// Реестр фоновых процессов; в тестах подменяется на изолированный.
    private let registry: BackgroundProcessRegistry
    init(registry: BackgroundProcessRegistry = .shared) {
        self.registry = registry
    }

    func execute(_ ctx: ToolContext) async -> ToolResult {
        guard let command = ctx.input("command"),
              !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .error("не указан аргумент command")
        }
        let timeout = min(max(ctx.intInput("timeoutSeconds") ?? Self.defaultTimeoutSeconds, 1),
                          Self.maxTimeoutSeconds)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = ctx.repoRoot
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = MCPEnv.augmentedPATH(extra: "")
        process.environment = env

        // stdout и stderr — в один pipe: модели важен общий журнал команды.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        // terminationHandler ставится ДО run(): мгновенно упавший процесс
        // иначе успел бы завершиться без резюма continuation.
        let terminated = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield(())
                continuation.finish()
            }
        }

        registry.register(process)
        do {
            try process.run()
        } catch {
            return .error("не удалось запустить команду: \(error.localizedDescription)")
        }

        // Чтение всего вывода параллельно ожиданию завершения — иначе
        // заполненный pipe заблокирует ребёнка (классический deadlock).
        let handle = pipe.fileHandleForReading
        let reader = Task.detached(priority: .utility) {
            (try? handle.readToEnd()) ?? Data()
        }
        // Сторож таймаута: SIGTERM, через 2 с — SIGKILL выжившему.
        let watchdog = Task.detached { [timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            guard !Task.isCancelled, process.isRunning else { return false }
            process.sendTerminationSignal()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { process.sendKillSignal() }
            return true
        }

        for await _ in terminated { break }
        watchdog.cancel()
        let timedOut = await watchdog.value
        let data = await reader.value

        var output = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        if output.count > Self.maxOutputChars {
            output = String(output.prefix(Self.maxOutputChars)) + "\n…(вывод обрезан)"
        }
        if timedOut {
            let tail = output.isEmpty ? "" : "\nВывод до остановки:\n\(output)"
            return .error("команда не завершилась за \(timeout) с и была остановлена.\(tail)")
        }
        let code = process.terminationStatus
        let body = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(команда не дала вывода)" : output
        return .ok("\(body)\n[exit code: \(code)]")
    }
}
