// FineTuneEnvironment.swift — поиск интерпретатора с mlx-lm (эталон — OllamaManager.findBinary).
//
// Порядок кандидатов как в finetune/mlxenv.py: явная переменная окружения,
// локальный venv тулчейна, python3.12/3.11/3.10 из PATH, системные каталоги.
// `candidates` — чистая функция (PATH берётся из переданного `environment`,
// вызывающий сам собирает его через MCPEnv.augmentedPATH); саму пробу
// (дорогую — до десятков секунд) делает `probe`, вызывающий обязан кэшировать.

import Foundation

struct FineTuneEnvironment {
    static let installHint = """
        mlx-lm не найден. Поставь его в отдельный venv:
            python3.12 -m venv finetune/.venv
            finetune/.venv/bin/pip install -r finetune/requirements.txt
        Либо укажи готовый интерпретатор через SB_FINETUNE_PYTHON.
        """

    static func candidates(fineTuneRoot: URL, environment: [String: String]) -> [URL] {
        var result: [URL] = []
        if let explicit = environment["SB_FINETUNE_PYTHON"], !explicit.isEmpty {
            result.append(URL(fileURLWithPath: explicit))
        }
        result.append(fineTuneRoot.appendingPathComponent(".venv/bin/python"))

        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for name in ["python3.12", "python3.11", "python3.10"] {
            for dir in pathDirs where !dir.isEmpty {
                result.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        result += [
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3")
        ]
        return result
    }

    /// Проба стоит десятки секунд на реальном mlx-lm — дефолт щедрый, но конечный:
    /// зависший интерпретатор не должен блокировать старт/выход приложения навсегда.
    static let defaultProbeTimeoutSeconds: TimeInterval = 30

    /// Успех = запуск `python -c "import mlx_lm"` завершился кодом 0 за отведённое время.
    /// Таймаут — SIGTERM, затем SIGKILL выжившему (образец — RunCommandTool).
    static func probe(_ python: URL, timeoutSeconds: TimeInterval = defaultProbeTimeoutSeconds) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import mlx_lm"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard semaphore.wait(timeout: .now() + timeoutSeconds) != .timedOut else {
            process.sendTerminationSignal()
            _ = semaphore.wait(timeout: .now() + 2)
            if process.isRunning { process.sendKillSignal() }
            return false
        }
        return process.terminationStatus == 0
    }
}
