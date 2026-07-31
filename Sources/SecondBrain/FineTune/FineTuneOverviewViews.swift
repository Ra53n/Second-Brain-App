// FineTuneOverviewViews.swift — вкладка «Обзор» выбранного датасета (задача 83).
//
// Статус пайплайна по шагам (FineTunePipelineStatus, чистое ядро) — каждый шаг со
// своей иконкой, деталью и кнопкой действия. Кнопки только переключают вкладку или
// зовут уже существующий метод ViewModel — сама генерация baseline/критериев
// с подтверждением перезаписи живёт на соответствующей вкладке, здесь только дверь.

import SwiftUI

struct FineTuneOverviewView: View {
    let dataset: FineTuneDataset
    @ObservedObject var store: FineTuneStore
    @ObservedObject var viewModel: FineTuneViewModel

    var body: some View {
        Form {
            Section {
                header
            }
            Section("Пайплайн") {
                ForEach(FineTunePipelineStatus.steps(input)) { step in
                    stepRow(step)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var input: FineTunePipelineStatus.Input {
        FineTunePipelineStatus.Input(
            trainCount: dataset.trainCount,
            validCount: dataset.validCount,
            validation: store.validationRecord(workdir: dataset.workdir),
            hasBaseline: dataset.baselineURL != nil,
            hasCriteria: dataset.criteriaURL != nil,
            hasTunedSnapshot: dataset.tunedURL != nil,
            runs: store.runs.filter { $0.workdir == dataset.workdir })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dataset.title).font(.headline)
            Text(dataset.rootURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func stepRow(_ step: FineTunePipelineStatus.Step) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(step.state).name)
                .foregroundStyle(icon(step.state).color)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.id.title)
                Text(detail(step.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let action = step.action {
                Button(actionLabel(action)) { perform(action) }
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ state: FineTunePipelineStatus.StepState) -> String {
        switch state {
        case .done(let text), .attention(let text), .missing(let text): return text
        }
    }

    private func icon(_ state: FineTunePipelineStatus.StepState) -> (name: String, color: Color) {
        switch state {
        case .done: return ("checkmark.circle.fill", .green)
        case .attention: return ("exclamationmark.triangle.fill", .orange)
        case .missing: return ("circle.dashed", .secondary)
        }
    }

    private func actionLabel(_ action: FineTunePipelineStatus.StepAction) -> String {
        switch action {
        case .openTab: return "Открыть"
        case .validate: return "Проверить"
        case .snapshotBaseline: return "Снять baseline"
        case .generateCriteria: return "Создать критерии"
        }
    }

    private func perform(_ action: FineTunePipelineStatus.StepAction) {
        switch action {
        case .openTab(let tab): store.datasetTab = tab
        case .validate: Task { await viewModel.validate(dataset: dataset) }
        case .snapshotBaseline: store.datasetTab = .baseline
        case .generateCriteria: store.datasetTab = .criteria
        }
    }
}
