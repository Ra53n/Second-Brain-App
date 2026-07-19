// VaultViews.swift — UI vault: экран приветствия, дерево файлов, инфо о файле.
//
// Здесь живут:
//  - VaultPane      — контейнер: приветствие (vault не открыт) или дерево;
//  - VaultTreeView  — дерево с контекстным меню CRUD и тулбаром;
//  - FileInfoView   — detail-панель: имя/размер/дата (редактор придёт в задаче 03).
//
// View только читают VaultManager и зовут его методы — вся логика там.

import SwiftUI

/// Контейнер колонки «Заметки»: приветствие, дерево или результаты поиска.
struct VaultPane: View {
    @ObservedObject var manager: VaultManager
    @ObservedObject var searchViewModel: SearchViewModel

    var body: some View {
        Group {
            if manager.root != nil {
                // Пока в поле поиска что-то есть — результаты вместо дерева.
                if searchViewModel.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    VaultTreeView(manager: manager, onRebuildSearchIndex: {
                        searchViewModel.rebuildIndex()
                    })
                } else {
                    SearchResultsView(searchViewModel: searchViewModel)
                }
            } else {
                welcome
            }
        }
        .searchable(
            text: $searchViewModel.query,
            placement: .toolbar,
            prompt: "Поиск по vault"
        )
        // Ошибки операций (занятое имя, недоступная папка…) — alert поверх колонки.
        .alert(
            "Ошибка",
            isPresented: Binding(
                get: { manager.lastError != nil },
                set: { if !$0 { manager.lastError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(manager.lastError?.localizedDescription ?? "") }
        )
    }

    /// Экран приветствия: открыть папку + список недавних vault.
    private var welcome: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Vault не открыт",
                systemImage: "folder",
                description: Text("Выберите папку с заметками —\nподойдёт существующий Obsidian vault.")
            )
            Button("Открыть vault…") { manager.openVaultPanel() }
                .keyboardShortcut("o", modifiers: .command)

            if !manager.recentVaults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Недавние")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(manager.recentVaults) { recent in
                        Button {
                            manager.openRecent(recent)
                        } label: {
                            Label(recent.name, systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.link)
                        .help(recent.path)
                    }
                }
            }
        }
        .padding()
    }
}

/// Дерево файлов vault с CRUD через контекстное меню и тулбар.
struct VaultTreeView: View {
    @ObservedObject var manager: VaultManager
    /// Команда «Пересоздать поисковый индекс» (живёт в SearchViewModel).
    var onRebuildSearchIndex: () -> Void = {}

    /// Узел, который переименовываем (nil — диалог закрыт), и черновик имени.
    @State private var renameTarget: VaultNode?
    @State private var renameDraft = ""

    var body: some View {
        // ScrollViewReader + рекурсивные DisclosureGroup вместо OutlineGroup:
        // reveal-механике (задача 42) нужно программно раскрывать предков
        // (manager.expandedFolders) и скроллить к цели — OutlineGroup держит
        // состояние раскрытия внутри себя и наружу его не отдаёт.
        ScrollViewReader { proxy in
            List(selection: $manager.selection) {
                if let root = manager.root {
                    VaultNodeRows(nodes: root.children ?? [], manager: manager) { node in
                        row(for: node)
                    }
                }
            }
            .onChange(of: manager.revealTick) { _, _ in
                guard let target = manager.revealTarget else { return }
                // Следующий кадр: только что раскрытые DisclosureGroup должны
                // успеть вставить строки, иначе scrollTo не найдёт id.
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(target.path, anchor: .center) }
                }
            }
        }
        .contextMenu { rootContextMenu }
        .toolbar { toolbar }
        // Диалог переименования: alert с текстовым полем (macOS 13+).
        .alert(
            "Переименовать",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Новое имя", text: $renameDraft)
            Button("Переименовать") {
                if let target = renameTarget {
                    manager.rename(target, to: renameDraft)
                }
                renameTarget = nil
            }
            Button("Отмена", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Расширение — часть имени (например, «Заметка.md»).")
        }
    }

    /// Строка дерева: иконка + имя + контекстное меню узла.
    /// .id — якорь для scrollTo при reveal (совпадает с VaultNode.id).
    private func row(for node: VaultNode) -> some View {
        Label(node.name, systemImage: node.systemImage)
            .tag(node.url)
            .id(node.id)
            .contextMenu { nodeContextMenu(node) }
    }

    // MARK: - Меню

    /// Контекстное меню узла: создать рядом, переименовать, переместить, удалить.
    @ViewBuilder
    private func nodeContextMenu(_ node: VaultNode) -> some View {
        Button("Новая заметка") {
            manager.selection = node.url
            manager.createNote()
        }
        Button("Новая папка") {
            manager.selection = node.url
            manager.createFolder()
        }
        Divider()
        Button("Переименовать…") {
            renameDraft = node.name
            renameTarget = node
        }
        moveMenu(for: node)
        Divider()
        Button("Удалить (в Корзину)", role: .destructive) {
            manager.trash(node)
        }
    }

    /// Подменю «Переместить в…» со всеми папками vault (кроме недопустимых целей).
    @ViewBuilder
    private func moveMenu(for node: VaultNode) -> some View {
        if let root = manager.root {
            Menu("Переместить в…") {
                ForEach(root.allFolders) { folder in
                    // Нельзя: в текущего родителя (no-op), в себя, внутрь себя.
                    let isCurrentParent = folder.url == node.url.deletingLastPathComponent().standardizedFileURL
                    let isSelfOrInside = folder.url.path == node.url.path
                        || folder.url.path.hasPrefix(node.url.path + "/")
                    if !isCurrentParent && !isSelfOrInside {
                        Button(folderTitle(folder)) {
                            manager.move(node, into: folder)
                        }
                    }
                }
            }
        }
    }

    /// Заголовок папки в меню перемещения: корень — по имени vault, остальные — путь от корня.
    private func folderTitle(_ folder: VaultNode) -> String {
        guard let vaultURL = manager.vaultURL else { return folder.name }
        if folder.url == vaultURL.standardizedFileURL { return "\(folder.name) (корень)" }
        let relative = folder.url.path.dropFirst(vaultURL.standardizedFileURL.path.count + 1)
        return String(relative)
    }

    /// Меню по пустому месту списка: создать в корне/выбранной папке.
    @ViewBuilder
    private var rootContextMenu: some View {
        Button("Новая заметка") { manager.createNote() }
        Button("Новая папка") { manager.createFolder() }
    }

    // MARK: - Тулбар

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                manager.createNote()
            } label: {
                Label("Новая заметка", systemImage: "square.and.pencil")
            }
            .help("Новая заметка")

            Button {
                manager.createFolder()
            } label: {
                Label("Новая папка", systemImage: "folder.badge.plus")
            }
            .help("Новая папка")

            Menu {
                Toggle("Показывать скрытые папки", isOn: $manager.showsDotItems)
                Divider()
                Button("Пересоздать поисковый индекс") { onRebuildSearchIndex() }
                Divider()
                Button("Сменить vault…") { manager.openVaultPanel() }
                Button("Закрыть vault") { manager.closeVault() }
            } label: {
                Label("Ещё", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Рекурсивные строки дерева: папка — DisclosureGroup с внешним состоянием
/// раскрытия (VaultManager.expandedFolders — так reveal может раскрывать
/// предков программно), файл — просто строка. Ведёт себя как OutlineGroup:
/// List ленив, свёрнутые поддеревья не строятся.
private struct VaultNodeRows<Row: View>: View {
    let nodes: [VaultNode]
    @ObservedObject var manager: VaultManager
    @ViewBuilder let row: (VaultNode) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                DisclosureGroup(isExpanded: expansionBinding(for: node)) {
                    VaultNodeRows(nodes: node.children ?? [], manager: manager, row: row)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
    }

    /// Биндинг раскрытия папки поверх общего Set в VaultManager.
    private func expansionBinding(for node: VaultNode) -> Binding<Bool> {
        Binding(
            get: { manager.expandedFolders.contains(node.id) },
            set: { expanded in
                if expanded {
                    manager.expandedFolders.insert(node.id)
                } else {
                    manager.expandedFolders.remove(node.id)
                }
            }
        )
    }
}

/// Detail-панель выбранного файла: пока только имя/размер/дата изменения.
/// Редактор markdown придёт в задаче 03 и заменит это view для .md файлов.
struct FileInfoView: View {
    let node: VaultNode

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.title3)
            if let details {
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Редактор появится в задаче 03.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Размер и дата изменения; читаем атрибуты на месте — файл мог измениться.
    private var details: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: node.url.path) else {
            return nil
        }
        var parts: [String] = []
        if !node.isDirectory, let size = attrs[.size] as? Int64 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let date = attrs[.modificationDate] as? Date {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
