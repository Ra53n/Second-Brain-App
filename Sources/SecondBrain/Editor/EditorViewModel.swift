// EditorViewModel.swift — состояние открытой заметки: загрузка, автосохранение, конфликты.
//
// Поток данных:
//   выбор файла в дереве → open(url) → text (@Published) → NSTextView
//        ↓ debounce 500 мс ($text, паттерн MA ChatViewModel)        ↑
//   autosave → Data.write(.atomic) → диск ← внешний редактор (Obsidian…)
//        ↑                                        ↓ FSEvents (rebuild дерева)
//   saveNow() при потере фокуса/закрытии    checkExternalChange()
//
// Инвариант №1: файл пользователя никогда не перезаписывается молча.
// Внешнее изменение при несохранённых правках → конфликт, решает пользователь:
// перечитать диск (свои правки в корзину) или сохранить свою версию РЯДОМ
// с суффиксом «(conflict)» — оригинал остаётся за внешней версией.

import SwiftUI
import Combine

/// Внешнее изменение открытого файла при несохранённых локальных правках.
struct ExternalConflict: Equatable {
    /// Содержимое файла на диске (внешняя версия).
    let diskContent: String
}

/// Владелец состояния редактора. Один на приложение — переключается между
/// файлами через open(url), сохраняя предыдущий файл перед переключением.
@MainActor
final class EditorViewModel: ObservableObject {

    /// Текст в редакторе. NSTextView пишет сюда через binding.
    @Published var text: String = ""
    /// Открытый файл; nil — редактор пуст.
    @Published private(set) var fileURL: URL?
    /// Активный конфликт «внешняя правка против моих несохранённых» — для диалога.
    @Published var conflict: ExternalConflict?
    /// Ошибки чтения/записи — для alert; не глотаем (CONVENTIONS.md).
    @Published var lastError: VaultError?

    /// Последнее содержимое, про которое мы знаем, что оно на диске.
    /// Сравнение с ним отличает «свои» изменения от внешних и лишние записи.
    private(set) var lastSavedText: String = ""

    var hasUnsavedChanges: Bool { text != lastSavedText }

    private var saveCancellable: AnyCancellable?
    private var terminateObserver: NSObjectProtocol?

    /// - Parameter debounceMilliseconds: пауза автосохранения после последнего
    ///   ввода; в тестах уменьшается, чтобы не ждать по полсекунды.
    init(debounceMilliseconds: Int = 500) {
        // Паттерн MA: debounce на $published-поле. dropFirst — начальное
        // значение "" не считается правкой.
        saveCancellable = $text
            .dropFirst()
            .debounce(for: .milliseconds(debounceMilliseconds), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveNow() }

        // Выход из приложения — последний шанс сохранить (debounce мог не успеть).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    // MARK: - Открытие/закрытие

    /// Открывает файл, предварительно сохранив предыдущий (правки не теряются
    /// при переключении по дереву до истечения debounce).
    func open(_ url: URL) {
        guard url != fileURL else { return }
        saveNow()
        conflict = nil
        fileURL = url
        do {
            let content = try Self.read(url)
            lastSavedText = content
            text = content
        } catch {
            lastSavedText = ""
            text = ""
            fileURL = nil
            lastError = .operationFailed("не удалось прочитать «\(url.lastPathComponent)»: \(error.localizedDescription)")
        }
    }

    /// Закрывает файл (переключение раздела/vault), сохранив правки.
    func close() {
        saveNow()
        fileURL = nil
        text = ""
        lastSavedText = ""
        conflict = nil
    }

    // MARK: - Сохранение

    /// Пишет правки на диск атомарно. Идемпотентен: без правок — no-op.
    ///
    /// Запись синхронная (не на utility-очереди, как сторы MA) — осознанно:
    /// корректность детекции конфликтов требует, чтобы lastSavedText менялся
    /// строго вместе с диском, а заметки малы и .atomic-запись мгновенна.
    func saveNow() {
        guard let fileURL, hasUnsavedChanges, conflict == nil else { return }
        let content = text
        do {
            try Data(content.utf8).write(to: fileURL, options: .atomic)
            lastSavedText = content
        } catch {
            lastError = .operationFailed("не удалось сохранить «\(fileURL.lastPathComponent)»: \(error.localizedDescription)")
        }
    }

    // MARK: - Внешние изменения (сигнал приходит от FSEvents через rebuild дерева)

    /// Сверяет открытый файл с диском. Диск совпадает с lastSavedText — это эхо
    /// нашей же записи, игнорируем. Иначе: без локальных правок — тихо перечитать;
    /// с правками — конфликт на решение пользователю.
    func checkExternalChange() {
        guard let fileURL, conflict == nil else { return }
        // Файл удалили/переименовали извне: текст остаётся в редакторе,
        // автосохранение при следующей правке воссоздаст файл — данные не теряем.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let diskContent = try? Self.read(fileURL), diskContent != lastSavedText else { return }

        if hasUnsavedChanges {
            conflict = ExternalConflict(diskContent: diskContent)
        } else {
            // Порядок важен: сначала lastSavedText, потом text — иначе debounce
            // сочтёт перечитанное правкой и запишет его обратно.
            lastSavedText = diskContent
            text = diskContent
        }
    }

    /// Решение конфликта: мои правки — в файл-копию «Имя (conflict).md» рядом,
    /// оригинал остаётся за внешней версией (её и показываем).
    func resolveConflictKeepingMine() {
        guard let fileURL, let conflict else { return }
        do {
            try VaultFileOperations.writeConflictCopy(for: fileURL, contents: text)
            lastSavedText = conflict.diskContent
            text = conflict.diskContent
            self.conflict = nil
        } catch let error as VaultError {
            lastError = error
        } catch {
            lastError = .operationFailed(error.localizedDescription)
        }
    }

    /// Решение конфликта: перечитать диск, мои правки отбрасываются.
    func resolveConflictReloadingDisk() {
        guard let conflict else { return }
        lastSavedText = conflict.diskContent
        text = conflict.diskContent
        self.conflict = nil
    }

    // MARK: - Чтение

    /// Чтение файла: UTF-8, при неудаче — авто-детект системной кодировки
    /// (старые заметки из TextEdit могут быть в UTF-16/cp1251).
    private static func read(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }
}
