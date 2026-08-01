// FineTuneStageEditorViews.swift — sheet редактора стадий чата тюнинга (задача 94):
// имя + промпт каждой стадии, добавление/удаление/порядок, сброс к шаблону.
//
// Каркас — FineTuneImportSheet (padding + minWidth/minHeight), черновик-паттерн —
// MCPServerEditorView (draft в @State, onSave коммитит только по кнопке «Сохранить»).

import SwiftUI

struct StageEditorSheet: View {
    @ObservedObject var viewModel: TuningChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: [InferenceStage]
    @State private var selectedID: UUID?

    init(viewModel: TuningChatViewModel) {
        self.viewModel = viewModel
        let initial = viewModel.stages ?? StagedInferenceCore.defaultStages()
        _draft = State(initialValue: initial)
        _selectedID = State(initialValue: initial.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Стадии первичного запроса").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                stageList
                Divider()
                if let index = selectedIndex {
                    stageEditor(index: index)
                } else {
                    Text("Стадий нет — добавьте хотя бы одну или сбросьте к шаблону.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            footer
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
    }

    // MARK: - Список стадий

    private var stageList: some View {
        VStack(spacing: 6) {
            List(draft, id: \.id, selection: $selectedID) { stage in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.name.isEmpty ? "(без имени)" : stage.name)
                    Text(firstLine(stage.prompt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(stage.id)
            }
            .frame(minWidth: 200, maxWidth: 220)
            HStack(spacing: 6) {
                Button {
                    addStage()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityValue("Добавить стадию")
                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityValue("Удалить стадию")
                .disabled(selectedIndex == nil)
                Button {
                    moveSelected(offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityValue("Переместить стадию вверх")
                .disabled(!canMove(offset: -1))
                Button {
                    moveSelected(offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityValue("Переместить стадию вниз")
                .disabled(!canMove(offset: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    // MARK: - Редактор выбранной стадии

    @ViewBuilder
    private func stageEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Имя стадии", text: $draft[index].name)
            Text("Промпт").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft[index].prompt)
                .font(.body.monospaced())
                .frame(minHeight: 180)
            Text("Плейсхолдеры: {{transcript}} — фрагмент; {{prev}} — выход предыдущей стадии; " +
                 "{{stage:N}} — выход стадии N. Последняя стадия обязана вернуть {\"action_items\": [...]}.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Низ листа

    private var footer: some View {
        HStack {
            Button("Сбросить к шаблону") {
                draft = StagedInferenceCore.defaultStages()
                selectedID = draft.first?.id
            }
            Spacer()
            Button("Отмена") { dismiss() }
            Button("Сохранить") {
                let stagesToSave = StagedInferenceCore.matchesDefault(draft) ? nil : draft
                viewModel.setStages(stagesToSave)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
    }

    private var canSave: Bool {
        guard !draft.isEmpty else { return false }
        return draft.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Мутации черновика

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return draft.firstIndex { $0.id == selectedID }
    }

    private func addStage() {
        let newStage = InferenceStage(name: "Новая стадия", prompt: "")
        let insertAt = selectedIndex.map { $0 + 1 } ?? draft.count
        draft.insert(newStage, at: insertAt)
        selectedID = newStage.id
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        draft.remove(at: index)
        selectedID = draft.indices.contains(index) ? draft[index].id : draft.last?.id
    }

    private func canMove(offset: Int) -> Bool {
        guard let index = selectedIndex else { return false }
        let target = index + offset
        return draft.indices.contains(target)
    }

    private func moveSelected(offset: Int) {
        guard let index = selectedIndex, canMove(offset: offset) else { return }
        draft.swapAt(index, index + offset)
    }
}
