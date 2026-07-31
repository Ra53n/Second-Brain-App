// FineTuneImportViews.swift — sheet импорта датасета из внешнего JSONL (задача 83).
//
// Только быстрое превью синтаксиса (FineTuneImportCore.parse); полная проверка —
// вкладка «Обзор» → «Проверить датасет» (validate.py) после создания.

import SwiftUI
import UniformTypeIdentifiers

struct FineTuneImportSheet: View {
    @ObservedObject var viewModel: FineTuneViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var fileURL: URL?
    @State private var name = ""
    @State private var showsFileImporter = false
    @State private var isSubmitting = false

    private static let allowedTypes: [UTType] = {
        var types: [UTType] = []
        if let jsonl = UTType(filenameExtension: "jsonl") { types.append(jsonl) }
        types.append(contentsOf: [.json, .plainText])
        return types
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Добавить датасет").font(.headline)
            Text("JSONL, по одному примеру в строке: [{\"role\":\"system\",…}, {\"role\":\"user\",…}, {\"role\":\"assistant\",…}].")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Выбрать файл…") { showsFileImporter = true }
                if let fileURL {
                    Text(fileURL.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                }
            }

            if let preview = viewModel.importPreview {
                previewSection(preview)
            }

            TextField("Имя датасета", text: $name)
                .disabled(fileURL == nil)

            if let error = viewModel.importErrorText {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Отмена") {
                    viewModel.resetImport()
                    dismiss()
                }
                Button("Импортировать") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canImport)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 320)
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: Self.allowedTypes) { result in
            handlePicked(result)
        }
        // Закрытие любым путём (Esc, свайп) — не только кнопкой «Отмена»: превью/ошибка
        // не должны пережить sheet до следующего открытия.
        .onDisappear { viewModel.resetImport() }
    }

    @ViewBuilder
    private func previewSection(_ preview: FineTuneImportCore.ParseResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(preview.examples.count) валидных примеров, \(preview.issues.count) отклонено")
                .font(.callout)
            ForEach(Array(preview.issues.prefix(5).enumerated()), id: \.offset) { _, issue in
                Text("строка \(issue.line) — \(issue.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private var canImport: Bool {
        guard !isSubmitting, fileURL != nil,
              let preview = viewModel.importPreview, preview.examples.count >= 2
        else { return false }
        return FineTuneImportCore.sanitizeName(name) != nil
    }

    private func handlePicked(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        fileURL = url
        if name.isEmpty {
            name = FineTuneImportCore.sanitizeName(url.deletingPathExtension().lastPathComponent) ?? ""
        }
        Task { await viewModel.loadImportPreview(url: url) }
    }

    private func submit() async {
        guard let sanitized = FineTuneImportCore.sanitizeName(name) else { return }
        isSubmitting = true
        let success = await viewModel.importDataset(name: sanitized)
        isSubmitting = false
        if success { dismiss() }
    }
}
