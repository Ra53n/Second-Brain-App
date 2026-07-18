// FileTools.swift — файловые инструменты агента (задача 39).
//
// Дополняют read-only набор задачи 21 реальными операциями: поиск по
// содержимому (search_files), создание/перезапись (write_file), точечная
// правка (edit_file) и удаление в Корзину (delete_file). Все пути от модели —
// недоверенный ввод через SafePath; разрешение на выполнение даёт слой
// ToolPermissions + approve-гейт в ChatToolAssembly (сюда вызов доходит уже
// одобренным).
//
// Vault-safety (инвариант №1 ARCHITECTURE.md): перезапись существующего
// файла разрешена только после его чтения в этом чате (read_file регистрирует
// mtime в FileOpsContext) и только если файл не изменился на диске с момента
// чтения. Удаление — через Корзину (trashItem), не безвозвратно.

import Foundation

// MARK: - Контекст файловых операций чата

/// Итог применённой файловой операции — персистится в ChatMessage.fileChanges
/// (история «что агент сделал с файлами», воспроизводимость по diff'ам).
struct FileChangeDisplay: Codable, Equatable, Identifiable {
    /// Вид операции — для бейджа в UI.
    enum Kind: String, Codable {
        case created, modified, deleted

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .modified
        }

        var label: String {
            switch self {
            case .created: return "создан"
            case .modified: return "изменён"
            case .deleted: return "удалён"
            }
        }
    }

    var id = UUID()
    var relativePath: String
    var kind: Kind
    /// Unified diff (обрезан до maxDiffChars) либо пояснение операции.
    var diff: String

    /// Кап diff'а в истории — chats.json не должен пухнуть от мегабайтных правок.
    static let maxDiffChars = 32 * 1024

    enum CodingKeys: String, CodingKey { case id, relativePath, kind, diff }

    init(relativePath: String, kind: Kind, diff: String) {
        self.relativePath = relativePath
        self.kind = kind
        self.diff = diff.count > Self.maxDiffChars
            ? String(diff.prefix(Self.maxDiffChars)) + "\n…(diff обрезан)"
            : diff
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .modified
        diff = try c.decodeIfPresent(String.self, forKey: .diff) ?? ""
    }
}

/// Контекст файловых операций одного чата: реестр чтений (mtime-guard
/// перезаписи) и накопитель применённых изменений текущего хода. Живёт в
/// ChatViewModel per-чат, инструментам передаётся через ToolContext.
actor FileOpsContext {
    /// mtime файла на момент последнего ПОЛНОГО чтения (обрезанное чтение
    /// не регистрируется — модель видела не весь файл).
    private var readMtimes: [String: Date] = [:]
    /// Применённые изменения — вычерпываются в сообщение после хода.
    private var changes: [FileChangeDisplay] = []

    /// Допуск сравнения дат: файловые системы округляют mtime.
    private static let mtimeTolerance: TimeInterval = 0.000_1

    func noteRead(path: String, mtime: Date?) {
        guard let mtime else { return }
        readMtimes[path] = mtime
    }

    /// Проверка перед перезаписью СУЩЕСТВУЮЩЕГО файла. nil — можно писать;
    /// иначе текст ошибки для модели.
    func overwriteError(path: String, currentMtime: Date?) -> String? {
        guard let readAt = readMtimes[path] else {
            return "файл «\(path)» существует и не был прочитан в этом чате — сначала read_file"
        }
        guard let currentMtime,
              abs(currentMtime.timeIntervalSince(readAt)) <= Self.mtimeTolerance else {
            return "файл «\(path)» изменился на диске после чтения — перечитай через read_file"
        }
        return nil
    }

    func record(_ change: FileChangeDisplay) {
        changes.append(change)
    }

    /// Забрать накопленные изменения (цепляются к сообщению хода/фазы).
    func drainChanges() -> [FileChangeDisplay] {
        defer { changes.removeAll() }
        return changes
    }
}

// MARK: - Общие помощники

/// Общие капы и проверки файловых инструментов.
enum FileToolSupport {
    /// Кап содержимого write_file (модель больше и не выдаст).
    static let maxWriteBytes = 256 * 1024
    /// Кап размера файла для edit_file/diff-превью.
    static let maxEditBytes = 1024 * 1024

    /// Текстовая ошибка чтения — для модели (Result требует Error).
    struct ReadFailure: Error { let message: String }

    /// mtime файла; nil — файла нет/не читается.
    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Текст существующего файла для правки/диффа. .failure — текст ошибки
    /// для модели (бинарник, не-UTF-8, слишком большой).
    static func readText(at url: URL, path: String,
                         maxBytes: Int = maxEditBytes) -> Result<String, ReadFailure> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(ReadFailure(message: "не удалось прочитать «\(path)»"))
        }
        guard data.count <= maxBytes else {
            return .failure(ReadFailure(message: "«\(path)» больше \(maxBytes / 1024) КБ — правка не поддерживается"))
        }
        guard !data.contains(0) else {
            return .failure(ReadFailure(message: "«\(path)» — бинарный файл"))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(ReadFailure(message: "«\(path)» не в кодировке UTF-8"))
        }
        return .success(text)
    }

    /// Атомарная запись с созданием промежуточных папок (путь уже проверен
    /// SafePath — папки создаются только внутри корня).
    static func write(_ text: String, to url: URL, path: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return nil
        } catch {
            return "не удалось записать «\(path)»: \(error.localizedDescription)"
        }
    }
}

// MARK: - search_files

/// Поиск литеральной подстроки по содержимому файлов проекта (без regex —
/// предсказуемая стоимость и надёжность для LLM; regex — вне объёма 39).
final class SearchFilesTool: BuiltinTool {
    static let defaultMatches = 50
    static let maxMatches = 200
    static let maxScannedFiles = 5000
    static let maxLineChars = 250
    static let maxOutputChars = 32 * 1024
    /// Файлы больше капа пропускаются (логи, дампы — шум для поиска).
    static let maxFileBytes = 1024 * 1024

    let name = "search_files"
    let description = "Поиск подстроки по содержимому файлов проекта (без учёта регистра). Возвращает строки вида путь:номер: текст."
    let parameters = ToolSchemas.object([
        "query": ToolSchemas.string("Искомая подстрока (литеральная, регистр не важен)."),
        "path": ToolSchemas.string("Подпапка относительно корня; пусто — весь проект."),
        "extension": ToolSchemas.string("Фильтр по расширению файла, например «md» или «swift»."),
        "maxResults": ToolSchemas.integer("Максимум совпадений (1–\(SearchFilesTool.maxMatches), по умолчанию \(SearchFilesTool.defaultMatches)).")
    ], required: ["query"])

    private let git: GitClient
    init(git: GitClient) { self.git = git }

    func execute(_ ctx: ToolContext) async -> ToolResult {
        guard let query = ctx.input("query"),
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .error("не указан аргумент query")
        }
        var prefix = ""
        if let path = ctx.input("path"), !path.isEmpty {
            guard SafePath.resolve(path, under: ctx.repoRoot) != nil else {
                return .error("путь «\(path)» вне корня проекта")
            }
            prefix = path.hasSuffix("/") ? path : path + "/"
        }
        let ext = ctx.input("extension")?
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased() ?? ""
        let limit = min(max(ctx.intInput("maxResults") ?? Self.defaultMatches, 1),
                        Self.maxMatches)

        // Список файлов — как в list_files: git ls-files, фолбэк — обход ФС.
        var files = (try? await git.trackedFiles()) ?? []
        if files.isEmpty {
            files = ListFilesTool.walkFileSystem(root: ctx.repoRoot)
        }
        if !prefix.isEmpty { files = files.filter { $0.hasPrefix(prefix) } }
        if !ext.isEmpty {
            files = files.filter { $0.lowercased().hasSuffix("." + ext) }
        }

        var lines: [String] = []
        var matchCount = 0
        var fileCount = 0
        var outputChars = 0
        var truncated = false

        for file in files.prefix(Self.maxScannedFiles) {
            guard let url = SafePath.resolve(file, under: ctx.repoRoot),
                  let data = try? Data(contentsOf: url),
                  data.count <= Self.maxFileBytes,
                  !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }

            var fileMatched = false
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                guard line.range(of: query, options: .caseInsensitive) != nil else { continue }
                let snippet = line.trimmingCharacters(in: .whitespaces)
                let clipped = snippet.count > Self.maxLineChars
                    ? String(snippet.prefix(Self.maxLineChars)) + "…" : snippet
                let entry = "\(file):\(number + 1): \(clipped)"
                lines.append(entry)
                outputChars += entry.count + 1
                matchCount += 1
                fileMatched = true
                if matchCount >= limit || outputChars >= Self.maxOutputChars {
                    truncated = matchCount >= limit ? files.count > 0 : true
                    break
                }
            }
            if fileMatched { fileCount += 1 }
            if matchCount >= limit || outputChars >= Self.maxOutputChars { break }
        }

        guard !lines.isEmpty else {
            return .ok("Ничего не найдено по «\(query)»\(prefix.isEmpty ? "" : " в «\(prefix)»").")
        }
        var out = lines
        out.append("Найдено: \(matchCount) совпадений в \(fileCount) файлах"
                   + (files.count > Self.maxScannedFiles
                      ? " (просканированы первые \(Self.maxScannedFiles) файлов)" : ""))
        if truncated {
            out.append("…(результат обрезан — уточните query/path/extension)")
        }
        return .ok(out.joined(separator: "\n"))
    }
}

// MARK: - write_file

/// Создание нового файла или перезапись прочитанного (mtime-guard).
final class WriteFileTool: BuiltinTool {
    let name = "write_file"
    let description = "Создать или перезаписать текстовый файл проекта. Перезапись существующего — только после его чтения через read_file в этом чате."
    let parameters = ToolSchemas.object([
        "path": ToolSchemas.string("Путь к файлу относительно корня проекта."),
        "content": ToolSchemas.string("Полное новое содержимое файла (до \(FileToolSupport.maxWriteBytes / 1024) КБ).")
    ], required: ["path", "content"])

    func execute(_ ctx: ToolContext) async -> ToolResult {
        guard let fileOps = ctx.fileOps else {
            return .error("запись файлов недоступна вне контекста чата")
        }
        guard let path = ctx.input("path"), !path.isEmpty else {
            return .error("не указан аргумент path")
        }
        guard let content = ctx.input("content") else {
            return .error("не указан аргумент content")
        }
        guard content.utf8.count <= FileToolSupport.maxWriteBytes else {
            return .error("content больше \(FileToolSupport.maxWriteBytes / 1024) КБ")
        }
        guard let url = SafePath.resolve(path, under: ctx.repoRoot) else {
            return .error("путь «\(path)» вне корня проекта или некорректен")
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            return .error("«\(path)» — папка")
        }

        var oldContent: String?
        if exists {
            // Vault-safety: перезапись только прочитанного и не изменившегося.
            if let error = await fileOps.overwriteError(
                path: path, currentMtime: FileToolSupport.modificationDate(of: url)) {
                return .error(error)
            }
            switch FileToolSupport.readText(at: url, path: path) {
            case .success(let text): oldContent = text
            case .failure(let failure): return .error(failure.message)
            }
        }

        if let error = FileToolSupport.write(content, to: url, path: path) {
            return .error(error)
        }
        // Свежий mtime в реестр — серия правок одного файла в одном ходе
        // не спотыкается о собственный guard.
        await fileOps.noteRead(path: path, mtime: FileToolSupport.modificationDate(of: url))

        let diff = UnifiedDiff.make(path: path, old: oldContent, new: content)
        await fileOps.record(FileChangeDisplay(
            relativePath: path,
            kind: exists ? .modified : .created,
            diff: diff.text.isEmpty ? "(содержимое не изменилось)" : diff.text))
        return .ok("OK: \(exists ? "перезаписан" : "создан") «\(path)» (\(diff.summary))")
    }
}

// MARK: - edit_file

/// Точечная замена old_string → new_string (дешевле по токенам и надёжнее
/// полной перезаписи: модель не переизлагает файл целиком).
final class EditFileTool: BuiltinTool {
    let name = "edit_file"
    let description = "Точечная правка текстового файла: заменить old_string на new_string. old_string должен встречаться ровно один раз (или укажи replace_all). Файл должен быть прочитан через read_file."
    let parameters = ToolSchemas.object([
        "path": ToolSchemas.string("Путь к файлу относительно корня проекта."),
        "old_string": ToolSchemas.string("Точный фрагмент текста, который нужно заменить."),
        "new_string": ToolSchemas.string("Новый текст вместо old_string."),
        "replace_all": .object(["type": .string("boolean"),
                                "description": .string("Заменить все вхождения (по умолчанию false — требуется уникальность).")])
    ], required: ["path", "old_string", "new_string"])

    func execute(_ ctx: ToolContext) async -> ToolResult {
        guard let fileOps = ctx.fileOps else {
            return .error("правка файлов недоступна вне контекста чата")
        }
        guard let path = ctx.input("path"), !path.isEmpty else {
            return .error("не указан аргумент path")
        }
        guard let oldString = ctx.input("old_string"), !oldString.isEmpty else {
            return .error("не указан аргумент old_string")
        }
        let newString = ctx.input("new_string") ?? ""
        let replaceAll = ctx.arguments["replace_all"]?.boolValue ?? false

        guard let url = SafePath.resolve(path, under: ctx.repoRoot) else {
            return .error("путь «\(path)» вне корня проекта или некорректен")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error("файл «\(path)» не найден")
        }
        if let error = await fileOps.overwriteError(
            path: path, currentMtime: FileToolSupport.modificationDate(of: url)) {
            return .error(error)
        }
        let text: String
        switch FileToolSupport.readText(at: url, path: path) {
        case .success(let value): text = value
        case .failure(let failure): return .error(failure.message)
        }

        let occurrences = text.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            return .error("old_string не найден в «\(path)» — перечитай файл через read_file")
        }
        guard occurrences == 1 || replaceAll else {
            return .error("old_string встречается \(occurrences) раз(а) в «\(path)» — расширь фрагмент до уникального или укажи replace_all")
        }

        let newText: String
        if replaceAll {
            newText = text.replacingOccurrences(of: oldString, with: newString)
        } else if let range = text.range(of: oldString) {
            newText = text.replacingCharacters(in: range, with: newString)
        } else {
            return .error("old_string не найден в «\(path)»")
        }

        if let error = FileToolSupport.write(newText, to: url, path: path) {
            return .error(error)
        }
        await fileOps.noteRead(path: path, mtime: FileToolSupport.modificationDate(of: url))

        let diff = UnifiedDiff.make(path: path, old: text, new: newText)
        await fileOps.record(FileChangeDisplay(
            relativePath: path, kind: .modified,
            diff: diff.text.isEmpty ? "(содержимое не изменилось)" : diff.text))
        return .ok("OK: правка «\(path)» применена (\(diff.summary))")
    }
}

// MARK: - delete_file

/// Удаление файла В КОРЗИНУ (trashItem) — обратимо, инвариант «не терять
/// файлы» соблюдён. Всегда dangerous в классификаторе.
final class DeleteFileTool: BuiltinTool {
    let name = "delete_file"
    let description = "Удалить файл проекта (перемещается в Корзину macOS, не безвозвратно)."
    let parameters = ToolSchemas.object([
        "path": ToolSchemas.string("Путь к файлу относительно корня проекта.")
    ], required: ["path"])

    func execute(_ ctx: ToolContext) async -> ToolResult {
        guard let fileOps = ctx.fileOps else {
            return .error("удаление файлов недоступно вне контекста чата")
        }
        guard let path = ctx.input("path"), !path.isEmpty else {
            return .error("не указан аргумент path")
        }
        guard let url = SafePath.resolve(path, under: ctx.repoRoot) else {
            return .error("путь «\(path)» вне корня проекта или некорректен")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .error("файл «\(path)» не найден")
        }
        guard !isDirectory.boolValue else {
            return .error("«\(path)» — папка; удаление папок не поддерживается")
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            return .error("не удалось удалить «\(path)»: \(error.localizedDescription)")
        }
        await fileOps.record(FileChangeDisplay(
            relativePath: path, kind: .deleted,
            diff: "(файл перемещён в Корзину)"))
        return .ok("OK: «\(path)» перемещён в Корзину")
    }
}

// MARK: - Превью для карточки подтверждения

/// Diff-превью правки ДО выполнения — для карточки approve (задача 39).
/// Повторяет план write/edit чистым чтением; расхождение с фактическим
/// выполнением невозможно по построению (те же аргументы, тот же диск).
enum FileChangePreview {
    /// nil — для этого инструмента превью не строится (покажем аргументы).
    static func detail(toolName: String, argumentsJSON: String, root: URL?) -> String? {
        guard let arguments = JSONValue.parse(argumentsJSON) else { return nil }
        switch toolName {
        case "run_command":
            return arguments["command"]?.stringValue.map { "$ \($0)" }
        case "delete_file":
            return arguments["path"]?.stringValue.map { "Удаление в Корзину: \($0)" }
        case "write_file":
            guard let root, let path = arguments["path"]?.stringValue,
                  let content = arguments["content"]?.stringValue,
                  let url = SafePath.resolve(path, under: root) else { return nil }
            var old: String?
            if FileManager.default.fileExists(atPath: url.path),
               case .success(let text) = FileToolSupport.readText(at: url, path: path) {
                old = text
            }
            let diff = UnifiedDiff.make(path: path, old: old, new: content)
            return diff.text.isEmpty ? "(содержимое не меняется)" : diff.text
        case "edit_file":
            guard let root, let path = arguments["path"]?.stringValue,
                  let oldString = arguments["old_string"]?.stringValue,
                  let url = SafePath.resolve(path, under: root),
                  case .success(let text) = FileToolSupport.readText(at: url, path: path)
            else { return nil }
            let newString = arguments["new_string"]?.stringValue ?? ""
            let replaceAll = arguments["replace_all"]?.boolValue ?? false
            let newText = replaceAll
                ? text.replacingOccurrences(of: oldString, with: newString)
                : text.range(of: oldString).map {
                    text.replacingCharacters(in: $0, with: newString)
                } ?? text
            guard newText != text else {
                return "(old_string не найден — вызов вернёт ошибку)"
            }
            let diff = UnifiedDiff.make(path: path, old: text, new: newText)
            return diff.text
        default:
            return nil
        }
    }
}
