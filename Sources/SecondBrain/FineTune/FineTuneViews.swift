// FineTuneViews.swift — раздел «Тюнинг»: средняя колонка + роутинг detail (задача 81).
//
// Средняя колонка — переключатель «Датасеты» | «Прогоны» над List(selection:),
// привязанным к общему FineTuneStore.selection (образец — PipelineViews.swift,
// PipelineStore.selectedPipelineID): выбор живёт в сторе, не в @State.
// Переключатель — ДВЕ кнопки тулбара (Label с иконкой), а не
// `Picker(.pickerStyle(.segmented))`: сегменты такого Picker на macOS не отдают
// подпись Accessibility вообще (ни name, ни value, ни description — та же
// природа, что у отсутствующего label DisclosureGroup) — проверено на этом
// экране эмпирически, оба варианта дают пустой AX. Кнопки тулбара (как
// «Новый пайплайн» у Пайплайнов) подпись отдают надёжно.
//
// Detail (FineTuneDetailView) роутит по типу выбора: датасет → просмотр
// (FineTuneDatasetViews.swift), всё остальное → консоль прогона
// (FineTuneRunViews.swift), которая сама умеет и стартовать новый прогон, и
// показывать выбранный/активный.

import SwiftUI

// MARK: - Средняя колонка

struct FineTunePane: View {
    @ObservedObject var store: FineTuneStore
    @ObservedObject var viewModel: FineTuneViewModel

    private enum Screen: String, CaseIterable, Identifiable {
        case datasets = "Датасеты"
        case runs = "Прогоны"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .datasets: return "tray.full"
            case .runs: return "chart.xyaxis.line"
            }
        }
    }

    @State private var screen: Screen = .datasets

    var body: some View {
        Group {
            switch screen {
            case .datasets: datasetsList
            case .runs: runsList
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(Screen.allCases) { option in
                    Button {
                        screen = option
                    } label: {
                        Label(option.rawValue, systemImage: option.systemImage)
                    }
                    .fontWeight(screen == option ? .bold : .regular)
                    .help(option.rawValue)
                }
            }
        }
        .task {
            await viewModel.refreshDatasets()
            await viewModel.checkEnvironment()
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

    @ViewBuilder
    private var runsList: some View {
        if store.runs.isEmpty {
            ContentUnavailableView("Прогонов ещё не было", systemImage: "chart.xyaxis.line",
                                   description: Text("Настройте и запустите тюн на экране «Прогон» справа."))
        } else {
            List(selection: $store.selection) {
                ForEach(store.runs) { run in
                    FineTuneRunRow(run: run)
                        .tag(FineTuneSelection.run(run.id))
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

    var body: some View {
        if case .dataset(let id) = store.selection,
           let dataset = viewModel.datasets.first(where: { $0.id == id }) {
            FineTuneDatasetDetailView(dataset: dataset, viewModel: viewModel)
                .id(dataset.id) // смена выбора пересоздаёт вид (сбрасывает @State)
        } else {
            // Всё остальное (выбран прогон или ничего не выбрано) — единая консоль
            // «Прогон»: сама стартует новый тюн и показывает активный/выбранный.
            FineTuneRunDetailView(store: store, viewModel: viewModel)
        }
    }
}
