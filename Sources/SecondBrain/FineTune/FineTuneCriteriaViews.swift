// FineTuneCriteriaViews.swift — детальный экран «Критерии» (задача 82, генерация — 83).
//
// Рендер criteria.md готовым markdown-слоем проекта (MarkdownUI) в режиме просмотра;
// «Править» переключает на TextEditor (моно) — документ пишет и человек, и LLM,
// расхождение с фактическим пересчётом на артефактах — вопрос к тексту, не к
// приложению (tasks/82-finetune-compare.md, «Допущения»).
//
// «Сгенерировать критерии» — тулбар, не инлайн-Button (та же причина, что у «Проверить
// датасет»/«Снять baseline»): кнопка в контент-области не отдаёт AX-подпись
// (FineTuneTabBar.swift). Существующий файл — confirmationDialog перезаписи.

import MarkdownUI
import SwiftUI

struct FineTuneCriteriaDetailView: View {
    let dataset: FineTuneDataset
    @ObservedObject var viewModel: FineTuneViewModel

    @State private var isEditing = false
    @State private var draft = ""
    @State private var showsOverwriteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.criteriaGenErrorText {
                Text(error).font(.caption).foregroundStyle(.red).padding(10)
                Divider()
            }
            content
        }
        .toolbar { toolbarContent }
        .confirmationDialog("Перезаписать criteria.md?", isPresented: $showsOverwriteConfirm,
                            titleVisibility: .visible) {
            Button("Перезаписать", role: .destructive) { startGeneration() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Существующий файл criteria.md будет заменён ответом модели.")
        }
        .task { await viewModel.loadCriteria(dataset: dataset) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isEditing {
                Button("Отмена") { isEditing = false }
                Button("Сохранить") { Task { await save() } }
            } else {
                if viewModel.isGeneratingCriteria {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        if dataset.criteriaURL != nil { showsOverwriteConfirm = true } else { startGeneration() }
                    } label: {
                        Label("Сгенерировать критерии", systemImage: "wand.and.stars")
                    }
                    .disabled(viewModel.isGeneratingCriteria)
                    if viewModel.criteriaText != nil {
                        Button {
                            draft = viewModel.criteriaText ?? ""
                            isEditing = true
                        } label: {
                            Label("Править", systemImage: "pencil")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .padding(8)
        } else if let text = viewModel.criteriaText {
            ScrollView {
                Markdown(text)
                    .markdownTheme(.docC)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            emptyState
        }
    }

    private func startGeneration() {
        Task { await viewModel.generateCriteria(dataset: dataset) }
    }

    private func save() async {
        if await viewModel.saveCriteria(dataset: dataset, text: draft) {
            isEditing = false
        }
    }

    // Кнопки здесь дублируют тулбарные для удобства — сами AX-подпись не отдают
    // (контент-область, см. FineTuneTabBar.swift), для смоука значимы только тулбарные.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("criteria.md не найден", systemImage: "doc.questionmark")
        } description: {
            Text("Ожидается файл \(criteriaHint).")
        } actions: {
            Button("Сгенерировать критерии") { startGeneration() }
                .disabled(viewModel.isGeneratingCriteria)
            Button("Создать вручную") {
                draft = "# Критерии качества\n\n"
                isEditing = true
            }
        }
    }

    private var criteriaHint: String {
        dataset.workdir == "." ? "finetune/criteria.md" : "finetune/\(dataset.workdir)/criteria.md"
    }
}
