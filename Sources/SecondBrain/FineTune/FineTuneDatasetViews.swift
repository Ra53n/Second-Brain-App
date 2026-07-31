// FineTuneDatasetViews.swift — детальный экран «Датасет» (задача 81).
//
// Шапка (путь, счётчики, сплит) → блок валидации (задача 82) → фильтр по task_type
// → список примеров → просмотр выбранного примера. Два текста (user/assistant)
// рядом — основной вид: на парах «тема → длинный пост» построчный diff честно
// вырождается в «заменено целиком», поэтому diff — только переключатель, не
// единственный способ сравнить.
//
// Кнопка «Проверить датасет» — в тулбаре, не инлайновый Button в теле экрана:
// как и в задаче 81 (переключатель «Датасеты»/«Прогоны»), инлайновые Button
// внутри этого экрана не отдают AX-подпись надёжно.

import SwiftUI

struct FineTuneDatasetDetailView: View {
    let dataset: FineTuneDataset
    @ObservedObject var viewModel: FineTuneViewModel
    @ObservedObject var store: FineTuneStore

    @State private var availableTaskTypes: [String] = []
    @State private var selectedExampleID: Int?
    @State private var showsDiff = false
    /// Считается по смене выбора/тумблера (см. `refreshDiff()`), не на каждый рендер
    /// body — `viewModel` публикует `errorText`/`isValidating` время от времени во время
    /// проверки, `UnifiedDiff.make` в body пересчитывался бы с той же частотой
    /// (antipattern 5, ревью задачи 82).
    @State private var diffText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            validationSection
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.validate(dataset: dataset) }
                } label: {
                    if viewModel.isValidating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Проверить датасет", systemImage: "checkmark.shield")
                    }
                }
                .disabled(viewModel.isValidating)
                .help("Запустить finetune/validate.py на этом датасете")
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
        .onChange(of: selectedExampleID) { _, _ in refreshDiff() }
        .onChange(of: showsDiff) { _, _ in refreshDiff() }
    }

    private func loadAll() async {
        viewModel.taskTypeFilter = nil
        await viewModel.loadExamples(dataset: dataset)
        availableTaskTypes = Array(Set(viewModel.examples.compactMap { $0.meta?.taskType }
            .filter { !$0.isEmpty })).sorted()
        selectedExampleID = viewModel.examples.first?.id
        showsDiff = false
        refreshDiff()
    }

    private func refreshDiff() {
        guard showsDiff, let example = viewModel.examples.first(where: { $0.id == selectedExampleID }) else {
            diffText = ""
            return
        }
        diffText = Self.diffText(example)
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

    /// Настройка `--min-assistant` + результат последней проверки (виден без
    /// повторного запуска — лежит в сторе, не в @State).
    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper("Минимальная длина ответа: \(minAssistantBinding.wrappedValue) симв.",
                    value: minAssistantBinding, in: 10...2000, step: 10)
            // validationErrorText — свой на validate() (P6): сам процесс не запустился/
            // завис, это ошибка уровня приложения, не результат валидации. Раньше здесь
            // читался общий errorText, и «не удалось остановить тюн» от другой кнопки
            // прятал последний результат проверки (ревью задачи 82).
            if let error = viewModel.validationErrorText {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let record = store.validationRecord(workdir: dataset.workdir) {
                validationResult(record)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var minAssistantBinding: Binding<Int> {
        Binding(get: { store.minAssistant(workdir: dataset.workdir, hasOwnSystemPrompt: dataset.systemPromptPath != nil) },
                set: { store.setMinAssistant($0, workdir: dataset.workdir) })
    }

    @ViewBuilder
    private func validationResult(_ record: FineTuneValidationRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: record.isValid ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(record.isValid ? .green : .red)
                Text(record.isValid ? "OK — датасет валиден"
                                    : "Датасет невалиден: \(record.issues.count) ошибок")
                    .font(.callout.bold())
                Spacer()
                Text(record.checkedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(record.notes, id: \.self) { note in
                Text(shortenNote(note)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(Array(record.issues.enumerated()), id: \.offset) { _, issue in
                Text(issueLine(issue)).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
    }

    /// `issue.file` от CLI — абсолютный путь; последние два компонента ("data/train.jsonl")
    /// достаточно, чтобы отличить train от valid, и не растягивают строку.
    private func issueLine(_ issue: FineTuneValidationRecord.Issue) -> String {
        let location = [issue.file.map(shortPath), issue.line.map(String.init)]
            .compactMap { $0 }.joined(separator: ":")
        return location.isEmpty ? issue.text : "\(location) — \(issue.text)"
    }

    private func shortPath(_ path: String) -> String {
        guard path.contains("/") else { return path }
        return path.split(separator: "/").suffix(2).joined(separator: "/")
    }

    /// `validate.py` пишет заметки как "<абсолютный путь>: <текст>" — с `lineLimit(1)`
    /// длинный путь съедал бы информативный хвост («уникальных текстов assistant N»),
    /// тот же shortPath(_:), что и для ошибок.
    private func shortenNote(_ note: String) -> String {
        guard let colon = note.firstIndex(of: ":") else { return note }
        let head = String(note[note.startIndex..<colon])
        guard head.contains("/") else { return note }
        return "\(shortPath(head)):\(note[note.index(after: colon)...])"
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
                        DiffTextView(diff: diffText)
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

    private static func diffText(_ example: FineTuneExample) -> String {
        let source = example.meta?.sourcePost ?? ""
        let path = source.isEmpty ? "example-\(example.id)" : source
        let result = UnifiedDiff.make(path: path, old: example.user, new: example.assistant)
        return result.text.isEmpty ? "(нет отличающихся строк)" : result.text
    }
}
