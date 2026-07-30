// FineTuneDatasetViews.swift — детальный экран «Датасет» (задача 81).
//
// Шапка (путь, счётчики, сплит) → фильтр по task_type → список примеров → просмотр
// выбранного примера. Два текста (user/assistant) рядом — основной вид: на парах
// «тема → длинный пост» построчный diff честно вырождается в «заменено целиком»,
// поэтому diff — только переключатель, не единственный способ сравнить.

import SwiftUI

struct FineTuneDatasetDetailView: View {
    let dataset: FineTuneDataset
    @ObservedObject var viewModel: FineTuneViewModel

    @State private var availableTaskTypes: [String] = []
    @State private var selectedExampleID: Int?
    @State private var showsDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterPicker
            Divider()
            HSplitView {
                examplesList
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                viewerPane
                    .frame(minWidth: 360)
            }
        }
        .task { await loadAll() }
        .onChange(of: viewModel.taskTypeFilter) { _, _ in
            Task {
                await viewModel.loadExamples(dataset: dataset)
                if !viewModel.examples.contains(where: { $0.id == selectedExampleID }) {
                    selectedExampleID = viewModel.examples.first?.id
                }
            }
        }
    }

    private func loadAll() async {
        viewModel.taskTypeFilter = nil
        await viewModel.loadExamples(dataset: dataset)
        availableTaskTypes = Array(Set(viewModel.examples.compactMap { $0.meta?.taskType }
            .filter { !$0.isEmpty })).sorted()
        selectedExampleID = viewModel.examples.first?.id
        showsDiff = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dataset.rootURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 12) {
                Text("\(dataset.trainCount) train / \(dataset.validCount) valid")
                if let split = dataset.split {
                    Text("сплит \(split.counts.train)/\(split.counts.valid)" +
                        (split.seed.map { ", seed \($0)" } ?? ""))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
        }
        .padding(10)
    }

    private var filterPicker: some View {
        Picker("Тип задания", selection: $viewModel.taskTypeFilter) {
            Text("Все").tag(String?.none)
            ForEach(availableTaskTypes, id: \.self) { type in
                Text(type).tag(String?.some(type))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var examplesList: some View {
        List(selection: $selectedExampleID) {
            ForEach(viewModel.examples) { example in
                HStack(spacing: 6) {
                    if let type = example.meta?.taskType, !type.isEmpty {
                        Text(type)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Text(firstLine(example.user))
                        .lineLimit(1)
                }
                .tag(example.id)
            }
        }
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    @ViewBuilder
    private var viewerPane: some View {
        if let example = viewModel.examples.first(where: { $0.id == selectedExampleID }) {
            VStack(alignment: .leading, spacing: 8) {
                if !example.system.isEmpty {
                    DisclosureGroup("System") {
                        Text(example.system)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                Toggle("Показать различия", isOn: $showsDiff)
                if showsDiff {
                    ScrollView {
                        DiffTextView(diff: diffText(example))
                    }
                } else {
                    HSplitView {
                        textPane(title: "Вход (user)", text: example.user)
                        textPane(title: "Эталон (assistant)", text: example.assistant)
                    }
                }
            }
            .padding(10)
        } else {
            ContentUnavailableView("Пример не выбран", systemImage: "doc.text",
                                   description: Text("Выберите строку датасета слева."))
        }
    }

    private func textPane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 220)
        .padding(6)
    }

    private func diffText(_ example: FineTuneExample) -> String {
        let source = example.meta?.sourcePost ?? ""
        let path = source.isEmpty ? "example-\(example.id)" : source
        let result = UnifiedDiff.make(path: path, old: example.user, new: example.assistant)
        return result.text.isEmpty ? "(нет отличающихся строк)" : result.text
    }
}
