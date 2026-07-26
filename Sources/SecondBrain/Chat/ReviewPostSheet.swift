// ReviewPostSheet.swift — превью постинга ревью в PR (вынесено из
// ChatViews.swift, задача 75, изначально задача 37).

import SwiftUI

/// Редактируемое превью + явное подтверждение перед POST-комментарием
/// (паттерн TitleConfirmationView встреч; правило бэклога №16 о write-
/// операциях). Ошибка отправки показывается здесь же — шит не закрывается.
struct ReviewPostSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    let context: ChatViewModel.ReviewPostContext

    @State private var commentBody: String
    @State private var errorText: String?
    @State private var isPosting = false

    init(viewModel: ChatViewModel, context: ChatViewModel.ReviewPostContext) {
        self.viewModel = viewModel
        self.context = context
        _commentBody = State(initialValue: context.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Комментарий в PR #\(String(context.target.number)) — \(context.target.owner)/\(context.target.repo)")
                .font(.headline)
            TextEditor(text: $commentBody)
                .font(.body.monospaced())
                .frame(minWidth: 480, minHeight: 240)
            if !viewModel.reviewPostTokenAvailable {
                Label("Нужен GitHub-токен с правом записи — Настройки → «Инструменты».",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorText {
                Label(errorText, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Отмена") { viewModel.reviewPostDialog = nil }
                Button(isPosting ? "Отправка…" : "Отправить в PR #\(String(context.target.number))") {
                    isPosting = true
                    errorText = nil
                    Task {
                        // nil = успех (диалог уже закрыт submitReviewPost'ом).
                        errorText = await viewModel.submitReviewPost(body: commentBody,
                                                                     context: context)
                        isPosting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPosting
                          || !viewModel.reviewPostTokenAvailable
                          || commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }
}
