// FineTuneBaselineViews.swift — детальный экран «Baseline» (задача 82, снятие — 83).
//
// Список снятых ответов датасета: слева строки (номер, тип задания, начало задания),
// справа выбранный — «Задание», «Ответ модели», «Эталон (текст автора)». Тумблер
// «Показать различия» — тот же UnifiedDiff/DiffTextView, что на экране «Датасет».
// Разбор outputs.json/*.md — FineTuneOutputsReader (чистое ядро), здесь только
// отображение готового FineTuneOutputsReader.Snapshot.
//
// Кнопка «Снять baseline» запускает `finetune/baseline.py` из приложения (задача 83):
// тулбар, не инлайн-Button — та же причина, что и у «Проверить датасет»
// (FineTuneDatasetViews.swift). Прогресса внутри прогона нет (baseline.py пишет
// результат только в конце) — indeterminate ProgressView + elapsed-таймер.

import SwiftUI

struct FineTuneBaselineDetailView: View {
    let dataset: FineTuneDataset
    @ObservedObject var store: FineTuneStore
    @ObservedObject var viewModel: FineTuneViewModel

    @State private var selectedAnswerID: String?
    @State private var showsDiff = false
    /// Считается по смене выбора/тумблера (см. `refreshDiff()`), не на каждый
    /// рендер body — `viewModel` публикует `logTail`/`statusText` раз в секунду во
    /// время прогона, `UnifiedDiff.make` в body пересчитывался бы с той же частотой
    /// (antipattern 5, второе вхождение, ревью задачи 82).
    @State private var diffText = ""
    @State private var showsOverwriteConfirm = false
    @State private var snapshotStartedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if viewModel.isSnapshottingBaseline {
                snapshotBanner
                Divider()
            }
            if let error = viewModel.baselineErrorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(10)
                Divider()
            }
            content
        }
        .toolbar { toolbarContent }
        .confirmationDialog("Перезаписать снятый baseline?", isPresented: $showsOverwriteConfirm,
                            titleVisibility: .visible) {
            Button("Перезаписать", role: .destructive) { startSnapshot() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Существующие ответы в baseline/ будут заменены новым прогоном baseline.py.")
        }
        .task { await load() }
        .onChange(of: selectedAnswerID) { _, _ in refreshDiff() }
        .onChange(of: showsDiff) { _, _ in refreshDiff() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Stepper("Примеров: \(countBinding.wrappedValue)", value: countBinding, in: countRange)
                .disabled(viewModel.isSnapshottingBaseline)
            if viewModel.isSnapshottingBaseline {
                ProgressView().controlSize(.small)
                Button {
                    Task { await viewModel.cancelBaselineSnapshot(dataset: dataset) }
                } label: {
                    Label("Отменить", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    if dataset.baselineURL != nil { showsOverwriteConfirm = true } else { startSnapshot() }
                } label: {
                    Label("Снять baseline", systemImage: "camera.viewfinder")
                }
                .disabled(!canSnapshot)
                .help(snapshotHelp)
            }
        }
    }

    private var countBinding: Binding<Int> {
        Binding(get: { store.baselineCountOverrides[dataset.workdir] ?? 10 },
                set: { store.setBaselineCount($0, workdir: dataset.workdir) })
    }

    private var countRange: ClosedRange<Int> { 1...max(dataset.validCount, 1) }

    private var isAnyTuneRunning: Bool { store.runs.contains { $0.status == .running } }

    private var canSnapshot: Bool { !viewModel.isSnapshottingBaseline && !isAnyTuneRunning }

    private var snapshotHelp: String {
        isAnyTuneRunning ? "Идёт обучение — дождитесь или остановите тюн."
                         : "Запустить finetune/baseline.py на этом датасете."
    }

    private func startSnapshot() {
        snapshotStartedAt = Date()
        Task { await viewModel.snapshotBaseline(dataset: dataset) }
    }

    private var snapshotBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Генерация \(countBinding.wrappedValue) ответов локальной моделью — " +
                 "это долго (минуты—десятки минут).")
                .font(.caption)
            Spacer()
            if let started = snapshotStartedAt {
                Text(started, style: .timer).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func load() async {
        await viewModel.loadBaseline(dataset: dataset)
        selectedAnswerID = viewModel.baselineSnapshot?.answers.first?.id
        showsDiff = false
        refreshDiff()
    }

    private func refreshDiff() {
        guard showsDiff, let answer = viewModel.baselineSnapshot?.answers
            .first(where: { $0.id == selectedAnswerID }) else {
            diffText = ""
            return
        }
        let result = UnifiedDiff.make(path: answer.id, old: answer.output, new: answer.reference)
        diffText = result.text.isEmpty ? "(нет отличающихся строк)" : result.text
    }

    @ViewBuilder
    private var header: some View {
        if let snapshot = viewModel.baselineSnapshot, !snapshot.answers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                let meta = metaLine(snapshot.meta)
                if !meta.isEmpty {
                    Text(meta).font(.callout).lineLimit(1)
                }
                Text("\(snapshot.answers.count) из \(dataset.validCount) примеров eval-сплита")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        }
    }

    /// Старый формат outputs.json (finetune/baseline/) не пишет провайдера/модель/
    /// адаптер/температуру вовсе — показываем только то, что реально есть (P6:
    /// молчать «nil» пользователю нельзя, но и придумывать значение тоже).
    private func metaLine(_ meta: FineTuneOutputsReader.Meta) -> String {
        var parts: [String] = []
        if let provider = meta.provider { parts.append("провайдер \(provider)") }
        if let model = meta.model { parts.append("модель \(model)") }
        if let adapter = meta.adapter { parts.append("адаптер \(adapter)") }
        if let temperature = meta.temperature { parts.append("температура \(temperature)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.baselineSnapshot {
            if !snapshot.answers.isEmpty {
                HSplitView {
                    answersList(snapshot.answers)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                    viewerPane(snapshot.answers)
                        .frame(minWidth: 360)
                }
            } else if !snapshot.textsOnly.isEmpty {
                textsOnlyList(snapshot.textsOnly)
            } else {
                emptyState
            }
        } else {
            emptyState
        }
    }

    private func answersList(_ answers: [FineTuneOutputsReader.Answer]) -> some View {
        List(selection: $selectedAnswerID) {
            ForEach(answers) { answer in
                HStack(spacing: 6) {
                    Text("\(answer.index)").font(.caption2).foregroundStyle(.secondary)
                    if let type = answer.taskType, !type.isEmpty {
                        Text(type)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Text(firstLine(answer.input)).lineLimit(1)
                }
                .tag(answer.id)
            }
        }
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    @ViewBuilder
    private func viewerPane(_ answers: [FineTuneOutputsReader.Answer]) -> some View {
        if let answer = answers.first(where: { $0.id == selectedAnswerID }) {
            VStack(alignment: .leading, spacing: 8) {
                textBlock(title: "Задание", text: answer.input)
                    .frame(maxHeight: 140)
                Toggle("Показать различия", isOn: $showsDiff)
                if showsDiff {
                    ScrollView {
                        DiffTextView(diff: diffText)
                    }
                } else {
                    HSplitView {
                        textBlock(title: "Ответ модели", text: answer.output)
                        textBlock(title: "Эталон (текст автора)", text: answer.reference)
                    }
                }
            }
            .padding(10)
        } else {
            ContentUnavailableView("Ответ не выбран", systemImage: "doc.text",
                                   description: Text("Выберите строку слева."))
        }
    }

    private func textBlock(title: String, text: String) -> some View {
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

    /// outputs.json без .md рядом (в репозитории не встречается, но парсер это
    /// допускает) — показываем сырые тексты по id, без «Задание»/«Эталон»: их
    /// в этом формате просто нет.
    private func textsOnlyList(_ texts: [String: String]) -> some View {
        List {
            ForEach(texts.sorted(by: { $0.key < $1.key }), id: \.key) { id, text in
                VStack(alignment: .leading, spacing: 4) {
                    Text(id).font(.caption.bold())
                    Text(text).font(.callout).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // Кнопка здесь дублирует тулбарную для удобства — сама она AX-подпись не отдаёт
    // (кнопка в контент-области, см. FineTuneTabBar.swift), для смоука значима только
    // тулбарная «Снять baseline».
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Baseline-ответы не сняты", systemImage: "tray")
        } description: {
            Text("Снимите ответы кнопкой «Снять baseline» в тулбаре.")
        } actions: {
            Button("Снять baseline") {
                if dataset.baselineURL != nil { showsOverwriteConfirm = true } else { startSnapshot() }
            }
            .disabled(!canSnapshot)
        }
    }
}
