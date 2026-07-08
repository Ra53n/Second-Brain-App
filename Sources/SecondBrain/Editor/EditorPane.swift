// EditorPane.swift — detail-панель заметки: редактор / сплит / превью + конфликты.
//
// Режимы: «Редактор» (NSTextView), «Сплит» (редактор + превью бок о бок),
// «Превью» (рендер MarkdownUI). Диалог конфликта появляется, когда файл
// изменили извне при несохранённых правках (EditorViewModel.conflict).

import SwiftUI
import MarkdownUI

/// Режим отображения заметки.
enum EditorMode: String, CaseIterable, Identifiable {
    case editor = "Редактор"
    case split = "Сплит"
    case preview = "Превью"
    var id: String { rawValue }
}

/// Панель открытой заметки. Владеет EditorViewModel; url приходит из дерева
/// (VaultManager.selection), внешние изменения — через rebuild дерева.
struct EditorPane: View {
    let url: URL
    @ObservedObject var vaultManager: VaultManager
    @StateObject private var viewModel = EditorViewModel()
    @State private var mode: EditorMode = .editor

    var body: some View {
        content
            .toolbar {
                ToolbarItem {
                    Picker("Режим", selection: $mode) {
                        ForEach(EditorMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Режим отображения заметки")
                }
            }
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

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            editorContent
            Divider()
            // Панель backlinks (задача 04) — под любым режимом отображения.
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

    @ViewBuilder
    private var editorContent: some View {
        switch mode {
        case .editor:
            wiredEditor
        case .split:
            HSplitView {
                wiredEditor
                    .frame(minWidth: 200)
                preview
                    .frame(minWidth: 200)
            }
        case .preview:
            preview
        }
    }

    /// Рендер markdown (swift-markdown-ui, как в MA), своя тема — Theme.secondBrain
    /// (Theme+SecondBrain.swift). Текст сначала проходит PreviewFilter: MarkdownUI
    /// не понимает Obsidian-синтаксис (^id, %% %%, ==выделение==) — без него он
    /// вылез бы нечитаемым сырым текстом, как в исходной жалобе. Текст выделяется мышью.
    private var preview: some View {
        ScrollView {
            Markdown(PreviewFilter.apply(viewModel.text))
                .markdownTheme(.secondBrain)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
