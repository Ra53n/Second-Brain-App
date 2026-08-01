// FineTuneRunViews.swift — вкладка «Прогоны» выбранного датасета (задача 81).
//
// Единая консоль на один датасет (задача 83: раньше — общий экран с Picker
// «Датасет», теперь дублирует и фильтрует всё по `dataset.workdir`): история
// прогонов этого датасета сверху, форма гиперпараметров (для нового прогона либо
// как читаемая сводка выбранного/активного — блокируется, пока прогон идёт),
// кнопки запуска/остановки/установки лучшего чекпоинта (в тулбаре — см. body),
// живой прогресс, график train/val loss (Charts) с отметкой лучшего чекпоинта по
// val loss (FineTuneCheckpointPicker — то же чистое ядро, что и у кнопки «Взять
// лучший»), хвост лога, предупреждение о памяти.

import Charts
import SwiftUI

struct FineTuneRunDetailView: View {
    let dataset: FineTuneDataset
    @ObservedObject var store: FineTuneStore
    @ObservedObject var viewModel: FineTuneViewModel

    @State private var draftModel: String = FineTuneViewModel.defaultModel
    @State private var draftHyperparameters = FineTuneHyperparameters()

    /// Прогоны этого датасета, свежие вверх (`store.runs` уже так упорядочен).
    private var datasetRuns: [FineTuneRun] { store.runs.filter { $0.workdir == dataset.workdir } }
    /// Активный прогон приоритетнее выбранного исторического — ViewModel в любой
    /// момент тянет лог только одного прогона, консоль всегда показывает именно его.
    private var activeRun: FineTuneRun? { datasetRuns.first { $0.status == .running } }
    private var selectedRun: FineTuneRun? {
        guard let id = store.selectedRunID else { return nil }
        return datasetRuns.first { $0.id == id }
    }
    private var displayedRun: FineTuneRun? { activeRun ?? selectedRun }
    private var isLocked: Bool { activeRun != nil }
    /// Лог/статус — только для прогона, который реально тайлится (В4): у ViewModel
    /// один хвост лога на все прогоны, показ его для чужого выбора в истории лгал бы.
    private var isTailed: Bool {
        guard let id = displayedRun?.id else { return false }
        return id == viewModel.tailedRunID
    }

    var body: some View {
        Form {
            historySection
            if viewModel.environmentReady == false {
                environmentBanner
            }
            externalRunBanner
            configSection
            statusSection
            if let run = displayedRun {
                progressSection(run)
                chartSection(run)
                if isTailed { logSection }
            }
            memorySection
        }
        .formStyle(.grouped)
        // Кнопки действий — в тулбаре, не инлайн-Section: обычный Button внутри
        // Form/Section на macOS не отдаёт Accessibility-подпись (name/value/
        // description — все пустые, проверено эмпирически на этом экране), кнопка
        // тулбара (как «Запустить» у PipelineEditorForm) подпись отдаёт надёжно.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await startTapped() }
                } label: {
                    Label("Запустить тюн", systemImage: "play.fill")
                }
                .disabled(isLocked || viewModel.environmentReady != true)
                Button {
                    if let run = activeRun { Task { await viewModel.stopCurrent(run: run) } }
                } label: {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .disabled(activeRun == nil)
                Button {
                    if let run = displayedRun { Task { await viewModel.installBest(run: run) } }
                } label: {
                    Label("Взять лучший чекпоинт", systemImage: "checkmark.seal")
                }
                .disabled(displayedRun == nil || !canInstallBest)
                .help(canInstallBest ? "" : "run.json датасета перезаписан другим тюном — этот прогон больше не текущий.")
            }
        }
        .onChange(of: displayedRun?.id) { _, _ in
            syncDraft()
            Task { await viewModel.refreshCurrentRun(dataset: dataset) }
        }
        .onAppear(perform: syncDraft)
        .task(id: dataset.workdir) { await viewModel.refreshCurrentRun(dataset: dataset) }
    }

    /// Кнопка «Взять лучший» недоступна прогону, чей run.json уже перезаписан другим
    /// тюном этого датасета (run.json/train.log — синглтоны на workdir, задача 92).
    private var canInstallBest: Bool {
        guard let run = displayedRun else { return false }
        return viewModel.isCurrentRun(run)
    }

    private func syncDraft() {
        guard let run = displayedRun else { return }
        draftModel = run.model
        draftHyperparameters = run.hyperparameters
    }

    /// Клик по строке выбирает прогон для просмотра (не запускает и не мутирует его).
    @ViewBuilder
    private var historySection: some View {
        if !datasetRuns.isEmpty {
            Section("История") {
                ForEach(datasetRuns) { run in
                    FineTuneRunRow(run: run)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(run.id == displayedRun?.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedRunID = run.id }
                }
            }
        }
    }

    /// mlx-lm не найден — баннер именно здесь, экран «Датасет» работает и без него.
    private var environmentBanner: some View {
        Section {
            Label {
                Text(FineTuneEnvironment.installHint)
                    .font(.caption.monospaced())
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
        }
    }

    /// Прогон обнаружен по живому pid, но запущен не нами (из терминала) — при
    /// выходе приложение его не тронет, инвариант №2 запрещает гасить чужой процесс.
    @ViewBuilder
    private var externalRunBanner: some View {
        if let run = displayedRun, run.isAdoptedExternally, run.status == .running {
            Section {
                Label("Прогон запущен вне приложения — при выходе он не будет остановлен.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var configSection: some View {
        Section("Гиперпараметры") {
            HStack {
                TextField("Модель", text: $draftModel)
                // accessibilityValue — по конвенции модуля; кнопка всё равно внутри
                // Form/Section, где, по опыту этого экрана (см. комментарий к тулбару
                // выше), AX не отдаёт даже её — смоук эту пару проверить не может,
                // только ручной клик.
                Button("3B") { draftModel = FineTuneViewModel.smallModel }
                    .buttonStyle(.bordered)
                    .accessibilityValue("3B")
                Button("7B") { draftModel = FineTuneViewModel.defaultModel }
                    .buttonStyle(.bordered)
                    .accessibilityValue("7B")
            }
            Stepper("Итерации: \(draftHyperparameters.iters)",
                    value: $draftHyperparameters.iters, in: 10...5000, step: 10)
            Stepper("Слои (LoRA): \(draftHyperparameters.numLayers)",
                    value: $draftHyperparameters.numLayers, in: 1...64)
            Stepper("Длина контекста: \(draftHyperparameters.maxSeqLength)",
                    value: $draftHyperparameters.maxSeqLength, in: 256...8192, step: 256)
            Stepper("Батч: \(draftHyperparameters.batchSize)",
                    value: $draftHyperparameters.batchSize, in: 1...32)
            TextField("Learning rate", text: $draftHyperparameters.learningRate)
            Stepper("Чекпоинт каждые: \(draftHyperparameters.saveEvery)",
                    value: $draftHyperparameters.saveEvery, in: 5...500, step: 5)
            Stepper("Валидация каждые: \(draftHyperparameters.stepsPerEval)",
                    value: $draftHyperparameters.stepsPerEval, in: 5...500, step: 5)
        }
        .disabled(isLocked)
    }

    /// Сами кнопки — в тулбаре (см. body); здесь только статус/ошибка запуска.
    /// statusText — только для тайлящегося прогона (В4, тот же резон, что и logSection);
    /// errorText — реакция на только что нажатую кнопку над ИМЕННО показанным прогоном,
    /// показывается независимо от тайлинга.
    @ViewBuilder
    private var statusSection: some View {
        if (isTailed && !viewModel.statusText.isEmpty) || viewModel.errorText != nil {
            Section {
                if isTailed, !viewModel.statusText.isEmpty {
                    Text(viewModel.statusText).font(.caption).foregroundStyle(.secondary)
                }
                if let error = viewModel.errorText {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func startTapped() async {
        await viewModel.start(dataset: dataset, model: draftModel, hyperparameters: draftHyperparameters)
        // Успешный старт — сразу переключить выбор на новый прогон (appendRun
        // кладёт свежие в начало store.runs), чтобы прогресс был виден без клика.
        if viewModel.errorText == nil, let newRun = datasetRuns.first {
            store.selectedRunID = newRun.id
        }
    }

    @ViewBuilder
    private func progressSection(_ run: FineTuneRun) -> some View {
        Section("Прогресс") {
            ProgressView(value: Double(min(latestIter(run), run.hyperparameters.iters)),
                        total: Double(max(run.hyperparameters.iters, 1)))
            Text(statusLine(run))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func latestIter(_ run: FineTuneRun) -> Int { run.points.last?.iter ?? 0 }

    /// «iter 150/300 · 11.4 с/итер · ETA ~28 мин · пик 11.3 ГБ» — чисто презентационная
    /// сборка строки из уже готовых точек лога, без разбора/парсинга.
    private func statusLine(_ run: FineTuneRun) -> String {
        let iter = latestIter(run)
        let total = run.hyperparameters.iters
        var parts = ["iter \(iter)/\(total)"]
        if let speed = run.points.last(where: { $0.itPerSec != nil })?.itPerSec, speed > 0 {
            parts.append(String(format: "%.1f с/итер", 1 / speed))
            if iter < total {
                parts.append(String(format: "ETA ~%.0f мин", Double(total - iter) / speed / 60))
            }
        }
        if let peak = run.points.compactMap(\.peakMemGB).last {
            parts.append(String(format: "пик %.1f ГБ", peak))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func chartSection(_ run: FineTuneRun) -> some View {
        Section("График loss") {
            Chart {
                ForEach(Array(run.points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Итерация", point.iter), y: .value("Loss", point.loss))
                        .foregroundStyle(by: .value("Серия", point.kind == .train ? "train" : "val"))
                }
                if let best = FineTuneCheckpointPicker.best(from: run.points) {
                    PointMark(x: .value("Итерация", best.iter), y: .value("Loss", best.valLoss))
                        .foregroundStyle(.green)
                        .symbolSize(90)
                    RuleMark(x: .value("Итерация", best.iter))
                        .foregroundStyle(.green.opacity(0.35))
                        .annotation(position: .top, alignment: .leading) {
                            Text("лучший чекпоинт")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                }
            }
            .frame(minHeight: 180)
        }
    }

    @ViewBuilder
    private var logSection: some View {
        Section("Лог") {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.logTail.isEmpty ? "Лог появится после старта прогона." : viewModel.logTail)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logTail")
                }
                .frame(minHeight: 120, maxHeight: 220)
                .onChange(of: viewModel.logTail) { _, _ in
                    proxy.scrollTo("logTail", anchor: .bottom)
                }
            }
        }
    }

    private var memorySection: some View {
        Section {
            Label("Тюн 7B-4bit: замеренный пик ~11.1 ГБ. Одновременный тяжёлый локальный " +
                  "чат может положить машину — блокировки нет, только предупреждение.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }
}
