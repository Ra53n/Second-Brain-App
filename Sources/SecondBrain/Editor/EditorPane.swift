// EditorPane.swift — detail-панель заметки: единый Live Preview редактор + конфликты.
//
// Один режим (не Редактор/Сплит/Превью — тот выбор не прижился, см. заголовок
// MarkdownEditorView.swift про Live Preview): заметка редактируется прямо в
// виде, похожем на рендер — MarkdownEditorView сам сворачивает/разворачивает
// разметку по курсору. Диалог конфликта появляется, когда файл изменили извне
// при несохранённых правках (EditorViewModel.conflict).

import SwiftUI

/// Панель открытой заметки. Владеет EditorViewModel; url приходит из дерева
/// (VaultManager.selection), внешние изменения — через rebuild дерева.
struct EditorPane: View {
    let url: URL
    @ObservedObject var vaultManager: VaultManager
    @StateObject private var viewModel = EditorViewModel()

    var body: some View {
        content
            .navigationTitle(url.lastPathComponent)
            .onAppear { viewModel.open(url) }
            .onChange(of: url) { _, newURL in viewModel.open(newURL) }
            // FSEvents (задача 02) — единственный сигнал «на диске что-то
            // поменялось». Подписка на тик, а не на root: правка содержимого
            // файла не меняет дерево, и onChange(of: root) промолчал бы.
            .onChange(of: vaultManager.diskChangeTick) { _, _ in viewModel.checkExternalChange() }
            .onDisappear { viewModel.close() }
            // Конфликт: внешняя правка против несохранённых своих. Молча не
            // перезаписываем ни одну из версий (инвариант №1).
            .confirmationDialog(
                "Файл изменён снаружи",
                isPresented: Binding(
                    get: { viewModel.conflict != nil },
                    set: { if !$0 { viewModel.conflict = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Перечитать с диска (мои правки пропадут)", role: .destructive) {
                    viewModel.resolveConflictReloadingDisk()
                }
                Button("Сохранить мою версию рядом (conflict)") {
                    viewModel.resolveConflictKeepingMine()
                }
            } message: {
                Text("«\(url.lastPathComponent)» изменили в другом редакторе, пока здесь есть несохранённые правки.")
            }
            .alert(
                "Ошибка",
                isPresented: Binding(
                    get: { viewModel.lastError != nil },
                    set: { if !$0 { viewModel.lastError = nil } }
                ),
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(viewModel.lastError?.localizedDescription ?? "") }
            )
    }

    private var content: some View {
        VStack(spacing: 0) {
            wiredEditor
            Divider()
            // Панель backlinks (задача 04) — под редактором.
            BacklinksView(url: url, vaultManager: vaultManager)
        }
    }

    /// Редактор с проводкой wikilinks: автокомплит из LinkIndex, Cmd+клик
    /// открывает/создаёт заметку через VaultManager.
    private var wiredEditor: MarkdownEditorView {
        MarkdownEditorView(
            text: $viewModel.text,
            completionTargets: { [weak vaultManager] in
                vaultManager?.linkIndex?.completionTargets ?? []
            },
            onWikilinkClick: { [weak vaultManager, weak viewModel] target in
                viewModel?.saveNow() // ссылка могла быть только что набрана
                vaultManager?.openWikilink(target)
            }
        )
    }
}
