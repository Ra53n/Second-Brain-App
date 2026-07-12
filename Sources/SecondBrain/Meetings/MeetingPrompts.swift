// MeetingPrompts.swift — промпты и парсеры этапа summary (стиль PipelinePrompts MA).
//
// Схема: user-сообщение — структурный блок [TRANSCRIPT]/[VAULT_FOLDERS]/
// [USER_RULES]/[PRESET_TITLE]; модель отвечает строго с маркерами TITLE:/FOLDER:/
// SUMMARY:. Парсер снисходителен: частичный ответ отдаёт что нашёл, ответ вовсе
// без маркеров целиком считается summary (название предложим из даты).
//
// Длинные встречи: транскрипт может не влезть в контекст маленькой модели —
// map-reduce: чанки ~24 тыс. символов (≈6–8 тыс. токенов) → промежуточные
// конспекты → финальный запрос по конспектам. Лимит подобран под типовые
// локальные модели с контекстом 8k; облачные прожуют и час встречи одним куском.

import Foundation

enum MeetingPrompts {
    static let titleMarker = "TITLE:"
    static let folderMarker = "FOLDER:"
    static let summaryMarker = "SUMMARY:"

    /// Порог, после которого включается map-reduce (символы транскрипта).
    static let maxTranscriptChars = 24_000

    // MARK: - Промпты

    /// Системный промпт этапа summary: роль + жёсткий формат ответа.
    static func systemPrompt() -> String {
        """
        Ты — ассистент, оформляющий рабочие встречи в базу знаний. По транскрипту \
        встречи составь конспект и предложи, как встречу назвать и в какую папку \
        положить. Отвечай СТРОГО в формате:
        \(titleMarker) <короткое название встречи, 3–7 слов, без даты>
        \(folderMarker) <папка из [VAULT_FOLDERS], подходящая по правилам [USER_RULES]>
        \(summaryMarker)
        <конспект: цели, ключевые решения, договорённости, action items с ответственными>
        Никакого текста вне этого формата. Название — на языке встречи. Папку выбирай \
        ТОЛЬКО из списка [VAULT_FOLDERS]; если ничего не подходит — оставь строку FOLDER: пустой.
        """
    }

    /// User-сообщение: структурный блок контекста.
    static func buildPrompt(transcript: String,
                            vaultFolders: [String],
                            userRules: String,
                            presetTitle: String?) -> String {
        let folders = vaultFolders.isEmpty ? "—" : vaultFolders.joined(separator: "\n           ")
        let rules = userRules.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = """
        [VAULT_FOLDERS] \(folders)
        [USER_RULES] \(rules.isEmpty ? "—" : rules)
        """
        if let presetTitle, !presetTitle.isEmpty {
            // Название уже задано пользователем — модель его не выдумывает,
            // но всё равно возвращает TITLE: (игнорируем) и подбирает папку под него.
            s += "\n[PRESET_TITLE] \(presetTitle)"
        }
        s += "\n\n[TRANSCRIPT]\n\(transcript)"
        return s
    }

    /// Промпт промежуточного конспекта одного чанка (map-фаза).
    static func chunkPrompt(chunk: String, index: Int, total: Int) -> String {
        """
        Это часть \(index + 1) из \(total) транскрипта длинной встречи. Сожми её в \
        подробный конспект: темы, решения, договорённости, action items. Не теряй \
        имена и цифры. Верни ТОЛЬКО конспект.

        [TRANSCRIPT_PART \(index + 1)/\(total)]
        \(chunk)
        """
    }

    // MARK: - Парсер ответа

    struct SummaryResponse: Equatable {
        var title: String?
        var folder: String?
        var summary: String
    }

    /// Разбор ответа модели. Снисходителен:
    ///  - TITLE:/FOLDER: — первая строка с маркером (регистр не важен);
    ///  - SUMMARY: — всё после маркера до конца текста (многострочный);
    ///  - нет SUMMARY: → summary = текст без строк TITLE/FOLDER;
    ///  - совсем мусор → весь текст как summary, title/folder = nil.
    static func parseSummaryResponse(_ text: String) -> SummaryResponse {
        var title: String?
        var folder: String?
        var summaryLines: [String] = []
        var inSummary = false

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            if inSummary {
                summaryLines.append(line)
                continue
            }
            if upper.hasPrefix(titleMarker) {
                let value = String(trimmed.dropFirst(titleMarker.count))
                    .trimmingCharacters(in: .whitespaces)
                if title == nil, !value.isEmpty { title = value }
            } else if upper.hasPrefix(folderMarker) {
                let value = String(trimmed.dropFirst(folderMarker.count))
                    .trimmingCharacters(in: .whitespaces)
                if folder == nil, !value.isEmpty { folder = value }
            } else if upper.hasPrefix(summaryMarker) {
                inSummary = true
                let inline = String(trimmed.dropFirst(summaryMarker.count))
                    .trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty { summaryLines.append(inline) }
            } else {
                // Любой текст вне маркеров (преамбула или конспект без SUMMARY:) —
                // копим как summary, чтобы частичный ответ не терял содержимое.
                summaryLines.append(line)
            }
        }

        var summary = summaryLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty, title == nil, folder == nil {
            summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return SummaryResponse(title: title, folder: folder, summary: summary)
    }

    // MARK: - Чанкование (map-reduce)

    /// Режет транскрипт на чанки ≤ maxChars по границам абзацев; абзац длиннее
    /// лимита режется жёстко. Пустой текст → пустой массив.
    static func chunkTranscript(_ text: String, maxChars: Int = maxTranscriptChars) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxChars else { return [trimmed] }

        var chunks: [String] = []
        var current = ""
        for paragraph in trimmed.components(separatedBy: "\n") {
            var piece = paragraph
            // Абзац-монстр длиннее лимита — режем жёстко по maxChars.
            while piece.count > maxChars {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(String(piece.prefix(maxChars)))
                piece = String(piece.dropFirst(maxChars))
            }
            let addition = current.isEmpty ? piece : "\n" + piece
            if current.count + addition.count > maxChars {
                chunks.append(current)
                current = piece
            } else {
                current += addition
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
