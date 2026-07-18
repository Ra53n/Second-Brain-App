// KnowledgeBase.swift — реестр баз знаний (задача 34).
//
// База знаний — источник RAG-ретрива: vault (заметки), репозиторий проекта
// (README + docs) или произвольная папка с .md. Реестр — единый список для
// чипа «База» в чате (мультивыбор per-чат) и инструмента rag_search.
//
// Встроенные базы vault/project зарезервированы: их id стабильны (миграция
// старого ChatConfiguration.knowledgeSource тривиальна), пути берутся из
// VaultManager/настроек, удалить их нельзя — только выключить. Папочные базы
// добавляет пользователь; у каждой свой индекс (см. FolderIndexService).
//
// Хранение: knowledge-bases.json в Application Support (паттерн
// MCPServerStore/ChatStore: атомарная запись, битый файл → карантин).

import Foundation

/// Тип базы знаний: определяет, кто отвечает за индекс и откуда путь.
enum KnowledgeBaseKind: String, Codable {
    case vault, project, folder
}

/// Одна база знаний реестра. id "vault"/"project" зарезервированы за
/// встроенными; папочные получают UUID-строку (стабилен при переименовании).
struct KnowledgeBase: Identifiable, Codable, Equatable {
    var id: String
    var kind: KnowledgeBaseKind
    /// Отображаемое имя — оно же значение параметра base инструмента rag_search.
    var name: String
    /// Корень папки (только kind == .folder; у встроенных пусто — путь
    /// известен VaultManager/настройкам).
    var path: String = ""
    /// Глобальный тумблер: выключенная база не видна ни в чате, ни в rag_search.
    var enabled: Bool = true

    static let vaultID = "vault"
    static let projectID = "project"

    /// Встроенная база: нельзя удалить/переименовать, путь не хранится.
    var isBuiltin: Bool { id == Self.vaultID || id == Self.projectID }

    init(id: String, kind: KnowledgeBaseKind, name: String,
         path: String = "", enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, kind, name, path, enabled }

    /// Снисходительное декодирование: незнакомый kind «из будущего» → .folder
    /// (normalize отбросит запись без пути), новые поля не ломают старый файл.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        kind = KnowledgeBaseKind(rawValue: rawKind) ?? .folder
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Встроенная запись vault (имя фиксировано — оно же в enum rag_search).
    static func builtinVault() -> KnowledgeBase {
        KnowledgeBase(id: vaultID, kind: .vault, name: "Vault")
    }

    /// Встроенная запись репозитория проекта.
    static func builtinProject() -> KnowledgeBase {
        KnowledgeBase(id: projectID, kind: .project, name: "Проект")
    }
}

/// Владелец реестра: загрузка/сохранение, нормализация, мутации для UI.
@MainActor
final class KnowledgeBaseStore: ObservableObject {
    @Published private(set) var bases: [KnowledgeBase]

    private let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        Config.appSupportDirectory.appendingPathComponent("knowledge-bases.json")
    }

    init(fileURL: URL = KnowledgeBaseStore.defaultFileURL) {
        self.fileURL = fileURL
        self.bases = Self.normalize(Self.load(from: fileURL))
    }

    func base(id: String) -> KnowledgeBase? {
        bases.first { $0.id == id }
    }

    /// Глобально включённые базы — кандидаты для чипа чата и rag_search.
    var enabledBases: [KnowledgeBase] { bases.filter(\.enabled) }

    /// Добавляет папочную базу. Повторное добавление того же пути возвращает
    /// существующую запись (дубликаты индексов не плодим).
    @discardableResult
    func addFolder(url: URL) -> KnowledgeBase {
        let path = url.standardizedFileURL.path
        if let existing = bases.first(where: { $0.kind == .folder && $0.path == path }) {
            return existing
        }
        let base = KnowledgeBase(id: UUID().uuidString, kind: .folder,
                                 name: url.lastPathComponent, path: path)
        bases.append(base)
        persist()
        return base
    }

    /// Удаляет папочную базу; встроенные удалить нельзя (только выключить).
    func removeBase(id: String) {
        guard let base = base(id: id), !base.isBuiltin else { return }
        bases.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(id: String, _ enabled: Bool) {
        guard let index = bases.firstIndex(where: { $0.id == id }) else { return }
        bases[index].enabled = enabled
        persist()
    }

    /// Переименование папочной базы (имя видно модели в enum rag_search).
    func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = bases.firstIndex(where: { $0.id == id }),
              !bases[index].isBuiltin else { return }
        bases[index].name = trimmed
        persist()
    }

    // MARK: - Нормализация и персистентность

    /// Инварианты реестра: встроенные vault/project существуют ровно по разу
    /// и стоят первыми (их enabled сохраняется), папочные записи без пути и
    /// дубликаты id отбрасываются.
    static func normalize(_ raw: [KnowledgeBase]) -> [KnowledgeBase] {
        var seen = Set<String>()
        var folders: [KnowledgeBase] = []
        var vault = KnowledgeBase.builtinVault()
        var project = KnowledgeBase.builtinProject()

        for base in raw {
            guard !seen.contains(base.id) else { continue }
            seen.insert(base.id)
            switch base.id {
            case KnowledgeBase.vaultID:
                vault.enabled = base.enabled
            case KnowledgeBase.projectID:
                project.enabled = base.enabled
            default:
                // Запись «из будущего» декодировалась как folder без пути —
                // отбрасываем: искать в ней нечем.
                guard base.kind == .folder, !base.path.isEmpty else { continue }
                folders.append(base)
            }
        }
        return [vault, project] + folders
    }

    private static func load(from url: URL) -> [KnowledgeBase] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([KnowledgeBase].self, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(bases) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
