// VaultManager.swift — владелец состояния vault: открытие, дерево, CRUD, наблюдение.
//
// Поток данных:
//   NSOpenPanel → openVault(url) → security-scoped bookmark в UserDefaults
//        ↓                                   (переживает перезапуск)
//   VaultTree.build → @Published root → сайдбар
//        ↑
//   VaultWatcher (FSEvents) и собственные CRUD зовут rebuild()
//
// Единственный владелец мутабельного состояния vault (паттерн из CONVENTIONS.md:
// один @MainActor ViewModel на область, View только читают). CRUD делегируется
// чистым VaultFileOperations, ошибки публикуются в lastError для alert'а.

import SwiftUI
import AppKit

/// Недавний vault для экрана приветствия: имя для UI + bookmark для открытия.
struct RecentVault: Identifiable, Equatable {
    let path: String
    let bookmark: Data
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Владелец состояния vault. Живёт один на приложение (создаётся в ContentView).
@MainActor
final class VaultManager: ObservableObject {

    /// Корень открытого vault; nil — vault не открыт (экран приветствия).
    @Published private(set) var vaultURL: URL?
    /// Снимок дерева файлов; перестраивается целиком на любое изменение.
    @Published private(set) var root: VaultNode?
    /// Выбранный в дереве узел (файл или папка). Файл отсюда заберёт редактор (задача 03).
    @Published var selection: URL?
    /// Раскрытые папки дерева (ключ — url.path, как VaultNode.id). Живёт здесь,
    /// а не во View: переживает rebuild по FSEvents и нужен reveal-механике.
    /// Протухшие пути удалённых папок безвредны — дерево их просто не найдёт.
    @Published var expandedFolders: Set<String> = []
    /// Цель последнего reveal-запроса — дерево скроллит к ней по revealTick.
    @Published private(set) var revealTarget: URL?
    /// Счётчик reveal-запросов. Тик, а не URL в onChange: повторный reveal
    /// той же цели (например, клик по тому же сегменту breadcrumb) тоже
    /// должен доскроллить дерево.
    @Published private(set) var revealTick = 0
    /// Показывать ли dot-папки (.obsidian, .git, …). Настройка из тулбара дерева.
    @Published var showsDotItems = false {
        didSet { rebuild() }
    }
    /// Последняя ошибка операции — для alert в UI; ошибки не глотаем (CONVENTIONS.md).
    @Published var lastError: VaultError?
    /// Недавние vault'ы для быстрого открытия с экрана приветствия.
    @Published private(set) var recentVaults: [RecentVault] = []
    /// Счётчик FSEvents-сигналов. Дерево (root) не меняется при правке лишь
    /// СОДЕРЖИМОГО файла — редактор подписывается на тик, а не на root, чтобы
    /// узнавать и о таких изменениях (checkExternalChange).
    @Published private(set) var diskChangeTick = 0
    /// Индекс связей vault (задача 04). nil, пока строится после открытия.
    /// LinkIndex — класс, in-place-мутации @Published не видит, поэтому View
    /// подписываются на linkVersion.
    private(set) var linkIndex: LinkIndex?
    /// Версия индекса связей: растёт после каждого построения/refresh.
    @Published private(set) var linkVersion = 0

    /// Стабильный id открытого vault — имя папки индексов в Application Support.
    var vaultID: String? {
        vaultURL.map { VaultID.make(for: $0) }
    }

    private var watcher: VaultWatcher?
    /// URL, у которого мы начали security-scoped доступ (для парного stop).
    private var scopedURL: URL?

    // Ключи UserDefaults. Bookmark, а не путь: переживает переименование папки
    // и готов к sandbox при дистрибуции (задача 18).
    private static let lastBookmarkKey = "vault.last.bookmark"
    private static let recentsKey = "vault.recent.bookmarks"
    private static let maxRecents = 5

    private let defaults: UserDefaults

    /// - Parameters:
    ///   - defaults: подменяется в тестах, чтобы не трогать реальные настройки;
    ///   - restoreLast: false в тестах/превью — не открывать vault с прошлого запуска.
    init(defaults: UserDefaults = .standard, restoreLast: Bool = true) {
        self.defaults = defaults
        loadRecents()
        // Для разработки: `SECONDBRAIN_VAULT=/path swift run` открывает vault
        // без диалога (env приоритетнее restore — как env-fallback у ключей).
        if let envPath = ProcessInfo.processInfo.environment["SECONDBRAIN_VAULT"] {
            openVault(at: URL(fileURLWithPath: envPath))
        } else if restoreLast, let data = defaults.data(forKey: Self.lastBookmarkKey) {
            if let url = Self.resolveBookmark(data) {
                openVault(at: url)
            }
        }
    }

    // MARK: - Открытие/закрытие vault

    /// Диалог выбора папки vault (любая папка, включая живой Obsidian vault).
    func openVaultPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Открыть vault"
        panel.message = "Выберите папку с заметками (например, ваш Obsidian vault)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVault(at: url)
    }

    /// Открывает vault: bookmark → доступ → дерево → FSEvents → recents.
    func openVault(at url: URL) {
        closeVault()

        // Security-scoped доступ: для не-sandbox сборки startAccessing вернёт
        // false — это нормально, доступ и так есть; при появлении sandbox
        // (задача 18) этот же код начнёт работать по-настоящему.
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }

        vaultURL = url
        rebuild()

        watcher = VaultWatcher(url: url) { [weak self] in
            guard let self else { return }
            self.diskChangeTick += 1
            self.rebuild()
            if self.linkIndex?.refresh() == true {
                self.linkVersion += 1
            }
        }

        // Индекс связей строится в фоне: на vault в тысячи заметок это сотни
        // миллисекунд, блокировать открытие незачем.
        let index = LinkIndex(root: url)
        Task.detached(priority: .userInitiated) { [weak self] in
            index.buildFull()
            await MainActor.run { [weak self] in
                guard let self, self.vaultURL == url else { return } // vault уже сменили
                self.linkIndex = index
                self.linkVersion += 1
            }
        }

        if let bookmark = Self.makeBookmark(for: url) {
            defaults.set(bookmark, forKey: Self.lastBookmarkKey)
            addRecent(path: url.standardizedFileURL.path, bookmark: bookmark)
        }
    }

    /// Открывает vault из списка недавних (bookmark мог протухнуть — тогда ошибка).
    func openRecent(_ recent: RecentVault) {
        guard let url = Self.resolveBookmark(recent.bookmark) else {
            lastError = .operationFailed("папка «\(recent.name)» недоступна (перемещена или удалена)")
            removeRecent(recent)
            return
        }
        openVault(at: url)
    }

    /// Закрывает vault: гасит наблюдатель, отпускает security scope, чистит состояние.
    func closeVault() {
        watcher?.stop()
        watcher = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        vaultURL = nil
        root = nil
        selection = nil
        expandedFolders = []
        revealTarget = nil
        linkIndex = nil
    }

    // MARK: - Навигация (breadcrumb, reveal в дереве — задача 42)

    /// Открывает URL «как пользователь»: выделяет узел (detail покажет
    /// редактор/папку) и раскрывает путь к нему в дереве.
    func open(_ url: URL) {
        selection = url.standardizedFileURL
        reveal(url)
    }

    /// Раскрывает предков url в дереве и просит VaultTreeView проскроллить
    /// к нему (через revealTick — см. комментарий у свойства).
    func reveal(_ url: URL) {
        guard let vaultURL else { return }
        expandedFolders.formUnion(VaultPath.ancestorPaths(of: url, within: vaultURL))
        revealTarget = url.standardizedFileURL
        revealTick += 1
    }

    /// Переход по [[ссылке]]: существующая заметка открывается, несуществующая —
    /// создаётся (как в Obsidian). Цель с «папка/Имя» создаёт промежуточные папки.
    func openWikilink(_ target: String) {
        if let url = linkIndex?.resolve(target) {
            open(url)
            return
        }
        guard let vaultURL else { return }
        perform {
            let noteURL = vaultURL.appendingPathComponent(target).appendingPathExtension("md")
            let folder = noteURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try VaultFileOperations.createNote(
                in: folder,
                named: noteURL.deletingPathExtension().lastPathComponent
            )
        }
        if let linkIndex, linkIndex.refresh() {
            linkVersion += 1
        }
    }

    // MARK: - CRUD (делегирование VaultFileOperations + rebuild)

    /// Папка-назначение для «создать»: выбранная папка, родитель выбранного файла
    /// или корень vault, если ничего не выбрано.
    var targetFolderForCreation: URL? {
        guard let vaultURL else { return nil }
        guard let selection, let node = root?.find(selection) else { return vaultURL }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    func createNote() {
        guard let folder = targetFolderForCreation else { return }
        perform { try VaultFileOperations.createNote(in: folder) }
    }

    func createFolder() {
        guard let folder = targetFolderForCreation else { return }
        perform { try VaultFileOperations.createFolder(in: folder) }
    }

    func createFile(named name: String) {
        guard let folder = targetFolderForCreation else { return }
        perform { try VaultFileOperations.createFile(in: folder, named: name) }
    }

    func rename(_ node: VaultNode, to newName: String) {
        perform { try VaultFileOperations.rename(node.url, to: newName) }
    }

    func move(_ node: VaultNode, into folder: VaultNode) {
        perform { try VaultFileOperations.move(node.url, into: folder.url) }
    }

    /// Удаление — только в Корзину (инвариант №1: файлы не теряем).
    func trash(_ node: VaultNode) {
        if selection == node.url { selection = nil }
        perform {
            try VaultFileOperations.trash(node.url)
            return nil
        }
    }

    /// Общий каркас CRUD: выполнить → выделить результат (с раскрытием пути
    /// в дереве) → перестроить дерево; VaultError показываем как есть,
    /// системные ошибки заворачиваем.
    private func perform(_ operation: () throws -> URL?) {
        do {
            if let resultURL = try operation() {
                open(resultURL)
            }
        } catch let error as VaultError {
            lastError = error
        } catch {
            lastError = .operationFailed(error.localizedDescription)
        }
        rebuild()
    }

    /// Перестраивает дерево с диска. Дёшево (иммутабельный снимок), зовётся
    /// после каждого CRUD и по FSEvents.
    func rebuild() {
        guard let vaultURL else { return }
        do {
            root = try VaultTree.build(at: vaultURL, showsDotItems: showsDotItems)
        } catch let error as VaultError {
            lastError = error
        } catch {
            lastError = .operationFailed(error.localizedDescription)
        }
    }

    // MARK: - Bookmarks и recents

    /// Bookmark с security scope; вне sandbox опция может быть недоступна —
    /// тогда откатываемся на обычный bookmark (путь всё равно сохраняется).
    private static func makeBookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        return try? url.bookmarkData()
    }

    /// Разрешает bookmark в URL (сначала как security-scoped, потом как обычный).
    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            return url
        }
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    private func loadRecents() {
        guard let stored = defaults.array(forKey: Self.recentsKey) as? [[String: Data]] else { return }
        recentVaults = stored.compactMap { dict in
            guard let bookmark = dict["bookmark"],
                  let pathData = dict["path"],
                  let path = String(data: pathData, encoding: .utf8) else { return nil }
            return RecentVault(path: path, bookmark: bookmark)
        }
    }

    private func addRecent(path: String, bookmark: Data) {
        var list = recentVaults.filter { $0.path != path }
        list.insert(RecentVault(path: path, bookmark: bookmark), at: 0)
        recentVaults = Array(list.prefix(Self.maxRecents))
        saveRecents()
    }

    private func removeRecent(_ recent: RecentVault) {
        recentVaults.removeAll { $0 == recent }
        saveRecents()
    }

    private func saveRecents() {
        let stored: [[String: Data]] = recentVaults.map {
            ["path": Data($0.path.utf8), "bookmark": $0.bookmark]
        }
        defaults.set(stored, forKey: Self.recentsKey)
    }
}
