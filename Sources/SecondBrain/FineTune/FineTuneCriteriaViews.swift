// FineTuneCriteriaViews.swift — детальный экран «Критерии» (задача 82).
//
// Рендер criteria.md готовым markdown-слоем проекта (MarkdownUI), без пересчёта:
// документ может расходиться с фактическим пересчётом на артефактах — это вопрос
// к тексту, не к приложению (tasks/82-finetune-compare.md, «Допущения»).

import MarkdownUI
import SwiftUI

struct FineTuneCriteriaDetailView: View {
    let dataset: FineTuneDataset
    @ObservedObject var viewModel: FineTuneViewModel

    var body: some View {
        Group {
            if let text = viewModel.criteriaText {
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
        .task { await viewModel.loadCriteria(dataset: dataset) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("criteria.md не найден", systemImage: "doc.questionmark")
        } description: {
            Text("Ожидается файл \(criteriaHint).")
        }
    }

    private var criteriaHint: String {
        dataset.workdir == "." ? "finetune/criteria.md" : "finetune/\(dataset.workdir)/criteria.md"
    }
}
