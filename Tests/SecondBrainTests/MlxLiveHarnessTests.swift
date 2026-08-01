// MlxLiveHarnessTests.swift — ручной live-прогон батч-confidence на реальном mlx_lm.server
// (задача 85). AX-доступ для кликов по UI недоступен в этой среде, поэтому живой прогон
// батча (критерий приёмки 7 — «батч baseline → тюн → батч тюна → summary.md») запускается
// этим тестом напрямую, теми же типами (`ConfidenceBatchRunner`, `MlxChatProvider`), что
// вызывает кнопка «Прогнать батч» в `FineTuneChatViews`.
//
// Каждый тест скипается, если не выставлена SB_MLX_LIVE=1 — обычный `./scripts/test.sh`
// не трогает сеть (инвариант «ноль сети в тестах»). Harness НЕ поднимает mlx_lm.server —
// им управляет человек из отдельного терминала:
//
//   cd finetune && source .venv/bin/activate   # или где стоит mlx-lm
//   python -m mlx_lm.server --model mlx-community/Qwen2.5-7B-Instruct-4bit \
//       --host 127.0.0.1 --port 18765
//   # для варианта .tuned — добавить --adapter-path finetune/meetings/adapters
//
// Запуск (baseline):
//   SB_MLX_LIVE=1 SB_MLX_VARIANT=baseline \
//     swift test --filter MlxLiveHarnessTests/testLiveBatchBaseline
// Запуск (тюн, сервер к тому моменту поднят с --adapter-path):
//   SB_MLX_LIVE=1 SB_MLX_VARIANT=tuned \
//     swift test --filter MlxLiveHarnessTests/testLiveBatchBaseline
//
// Отчёты пишутся туда же, куда пишет кнопка UI: finetune/meetings/confidence/{variant}.md
// (+ summary.md, когда на диске уже есть оба варианта) — те же артефакты критерия 7.

import XCTest
@testable import SecondBrain

@MainActor
final class MlxLiveHarnessTests: XCTestCase {

    /// Корень репозитория — три уровня вверх от Tests/SecondBrainTests/<файл>.swift.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLiveBatchBaseline() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SB_MLX_LIVE"] == "1",
                           "ручной live-прогон: SB_MLX_LIVE=1")

        let fineTuneRoot = repoRoot.appendingPathComponent("finetune")
        let datasets = FineTuneDatasetScanner.scan(fineTuneRoot: fineTuneRoot)
        guard let meetings = datasets.first(where: { $0.id == "meetings" }) else {
            throw XCTSkip("finetune/meetings не найден в этом чекауте")
        }
        guard let systemPath = meetings.systemPromptPath,
              let system = try? String(contentsOfFile: systemPath, encoding: .utf8), !system.isEmpty else {
            throw XCTSkip("finetune/meetings/system_prompt.txt не найден или пуст")
        }

        let variantRaw = ProcessInfo.processInfo.environment["SB_MLX_VARIANT"] ?? "baseline"
        let variant = FineTuneModelVariant(rawValue: variantRaw) ?? .baseline

        let provider = MlxChatProvider(port: 18765)
        let runner = ConfidenceBatchRunner()

        let url = try await runner.run(dataset: meetings, variant: variant, provider: provider, system: system)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(variant.rawValue).md обязан появиться на диске")
        let jsonURL = meetings.rootURL.appendingPathComponent("confidence/\(variant.rawValue).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
    }

}
