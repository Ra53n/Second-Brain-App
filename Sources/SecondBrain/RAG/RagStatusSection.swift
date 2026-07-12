// RagStatusSection.swift — секция статуса RAG-индекса в «Настройках»
// (задача 13): сколько заметок/чанков, когда обновлён, какой моделью;
// кнопки «Переиндексировать» (инкрементально) и «Заново» (полная), прогресс,
// предупреждение о смене модели эмбеддинга, ignore-список.

import SwiftUI

struct RagStatusSection: View {
    @ObservedObject var manager: RagIndexManager

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Section("База знаний (RAG-индекс)") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(manager.fileCount) заметок · \(manager.chunkCount) чанков")
                    HStack(spacing: 6) {
                        if let updatedAt = manager.updatedAt {
                            Text("обновлён \(Self.dateFormatter.string(from: updatedAt))")
                        }
                        if let tag = manager.embeddingTag {
                            Text("модель: \(tag)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let progress = manager.progress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress.fraction)
                            .frame(width: 120)
                        Text(progress.currentFile)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 160)
                        Button {
                            manager.cancelIndexing()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button("Переиндексировать") { manager.reindex() }
                    Button("Заново") { manager.reindex(fullRebuild: true) }
                        .help("Полная переиндексация с нуля (например, после смены модели эмбеддинга)")
                }
            }

            if manager.needsFullReindex {
                Label("Модель эмбеддинга изменилась — векторы несовместимы. Нажмите «Заново».",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if let error = manager.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            DisclosureGroup("Исключения (пути, по строке)") {
                TextEditor(text: $manager.ignoreList)
                    .font(.callout.monospaced())
                    .frame(minHeight: 40, maxHeight: 80)
                Text("Всегда исключаются: скрытые папки, Meetings/_recordings, не-markdown файлы.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
