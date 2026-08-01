// FineTuneViews.swift — раздел «Тюнинг»: средняя колонка + роутинг detail (задача 81).
//
// Средняя колонка — только список датасетов (задача 83: раньше здесь был
// переключатель «Датасеты»/«Прогоны»/«Baseline»/«Критерии» кнопками тулбара —
// подсветка активного `.fontWeight(.bold)` визуально не читалась). Detail-экран
// выбранного датасета сам переключает содержимое вкладками `FineTuneTabBar`
// (`store.datasetTab`) — навигация «вкладки внутри датасета», не сегменты списка.
//
// FineTuneDetailView: нет выбранного датасета → подсказка выбрать; есть →
// таб-бар + контент активной вкладки. «Прогоны» — консоль `FineTuneRunViews.swift`
// (сама умеет и стартовать новый, и показывать выбранный/активный по этому
// датасету), «Обзор» — статус пайплайна, «Примеры»/«Baseline»/«Критерии» — их
// артефакты (FineTuneDatasetViews.swift / FineTuneBaselineViews.swift /
// FineTuneCriteriaViews.swift).

import SwiftUI

// MARK: - Средняя колонка

struct FineTunePane: View {
    @ObservedObject var store: FineTuneStore
    @ObservedObject var viewModel: FineTuneViewModel
    @State private var showsImportSheet = false

    var body: some View {
        datasetsList
            .task {
                await viewModel.refreshDatasets()
                await viewModel.checkEnvironment()
            }
            // Снаружи if в datasetsList — кнопка доступна и в пустом состоянии
            // (нет датасетов лежит в finetune/, но импорт всё равно возможен).
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsImportSheet = true
                    } label: {
                        Label("Добавить датасет", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showsImportSheet) {
                FineTuneImportSheet(viewModel: viewModel)
            }
    }

    @ViewBuilder
    private var datasetsList: some View {
        if viewModel.datasets.isEmpty {
            emptyDatasetsState
        } else {
            List(selection: $store.selection) {
                ForEach(viewModel.datasets) { dataset in
                    FineTuneDatasetRow(dataset: dataset, isRunning: isRunning(dataset))
                        .tag(FineTuneSelection.dataset(dataset.id))
                }
            }
        }
    }

    private func isRunning(_ dataset: FineTuneDataset) -> Bool {
        store.runs.contains { $0.workdir == dataset.workdir && $0.status == .running }
    }

    /// Три причины пустого списка датасетов различимы через типизированное
    /// datasetsState (не через errorText, который пишут и другие операции —
    /// antipattern 5): путь в настройках, каталог finetune/ или сам датасет.
    @ViewBuilder
    private var emptyDatasetsState: some View {
        switch viewModel.datasetsState {
        case .noRepo:
            ContentUnavailableView {
                Label("Не задан репозиторий проекта", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Датасеты тюнинга лежат в <репозиторий>/finetune — укажите путь к проекту.")
            } actions: {
                SettingsLink { Text("Открыть настройки") }
            }
        case .noDirectory:
            ContentUnavailableView {
                Label("Каталог finetune/ не найден", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Соберите датасет из vault: python3 finetune/build_dataset.py --out finetune/data")
            }
        case .empty, .ready:
            ContentUnavailableView {
                Label("Датасетов пока нет", systemImage: "tray")
            } description: {
                Text("Соберите датасет из vault: python3 finetune/build_dataset.py --out finetune/data")
            }
        }
    }
}

/// Строка датасета: имя каталога, счётчики строк, точка — идёт ли по нему прогон.
struct FineTuneDatasetRow: View {
    let dataset: FineTuneDataset
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                Circle().fill(Color.blue).frame(width: 8, height: 8)
                    .help("Идёт прогон на этом датасете")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(dataset.title).lineLimit(1)
                Text("\(dataset.trainCount) train / \(dataset.validCount) valid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Строка истории прогонов: датасет, короткое имя модели, статус цветом, итерация, дата.
struct FineTuneRunRow: View {
    let run: FineTuneRun

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(run.datasetTitle).lineLimit(1)
                    Text("·").foregroundStyle(.secondary)
                    Text(shortModelName).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let last = run.points.last {
                        Text("iter \(last.iter)/\(run.hyperparameters.iters)")
                    }
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var shortModelName: String {
        run.model.split(separator: "/").last.map(String.init) ?? run.model
    }

    /// Палитра как в PipelineViews: running синий, finished зелёный,
    /// stopped/interrupted оранжевый, failed красный.
    private var color: Color {
        switch run.status {
        case .running: return .blue
        case .finished: return .green
        case .stopped, .interrupted: return .orange
        case .failed: return .red
        }
    }
}

// MARK: - Роутинг detail

struct FineTuneDetailView: View {
    @ObservedObject var store: FineTuneStore
    @ObservedObject var viewModel: FineTuneViewModel
    /// Мини-чат оценки уверенности (задача 85) — вкладка «Чат».
    @ObservedObject var chatViewModel: TuningChatViewModel
    @ObservedObject var mlxServer: MlxServerManager
    /// Пикер цели эскалации (задача 91) — провайдеры и модели чата.
    @ObservedObject var registry: ProviderRegistry

    var body: some View {
        Group {
            if let dataset = selectedDataset {
                VStack(spacing: 0) {
                    FineTuneTabBar(selection: $store.datasetTab)
                    Divider()
                    tabContent(dataset)
                }
            } else {
                selectDatasetPrompt
            }
        }
        // Без выбора первый заход всегда требовал бы лишнего клика ради «Датасет не
        // выбран» (список датасетов через AX ненадёжен, задача 82). Решение и
        // мутация selection — в сторе (View только зовёт).
        .onAppear { store.selectFirstDatasetIfNeeded(datasets: viewModel.datasets) }
        .onChange(of: viewModel.datasets) { _, _ in store.selectFirstDatasetIfNeeded(datasets: viewModel.datasets) }
    }

    @ViewBuilder
    private func tabContent(_ dataset: FineTuneDataset) -> some View {
        switch store.datasetTab {
        case .overview:
            FineTuneOverviewView(dataset: dataset, store: store, viewModel: viewModel)
                .id(dataset.id)
        case .examples:
            FineTuneDatasetDetailView(dataset: dataset, viewModel: viewModel, store: store)
                .id(dataset.id) // смена выбора пересоздаёт вид (сбрасывает @State)
        case .baseline:
            FineTuneBaselineDetailView(dataset: dataset, store: store, viewModel: viewModel)
                .id(dataset.id)
        case .criteria:
            FineTuneCriteriaDetailView(dataset: dataset, viewModel: viewModel)
                .id(dataset.id)
        case .runs:
            FineTuneRunDetailView(dataset: dataset, store: store, viewModel: viewModel)
                .id(dataset.id)
        case .chat:
            FineTuneChatDetailView(dataset: dataset, viewModel: chatViewModel, server: mlxServer, registry: registry)
                .id(dataset.id)
        }
    }

    private var selectedDataset: FineTuneDataset? {
        guard case .dataset(let id) = store.selection else { return nil }
        return viewModel.datasets.first { $0.id == id }
    }

    private var selectDatasetPrompt: some View {
        ContentUnavailableView("Датасет не выбран", systemImage: "tray.full",
                               description: Text("Выберите датасет в средней колонке."))
    }
}
