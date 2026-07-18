// ChatPromptBuilder.swift — системный промпт чата из секций (порт PromptBuilder MA).
//
// Секции опциональны и добавляются по мере появления подсистем:
//  - база — роль ассистента «второго мозга»;
//  - [RAG_CONTEXT] — найденные фрагменты vault (задача 14);
//  - [PROJECT_DOCS] — документация выбранного проекта для /help (задача 22);
//  - [TOOLS] — доступные MCP-инструменты (задача 15, пока заготовка).
//
// Правило из MA: контекстные секции помечаются «используй как контекст, не
// упоминай его существование» — иначе модель пересказывает служебные блоки.

import Foundation

enum ChatPromptBuilder {
    /// Базовая роль ассистента.
    static let basePrompt = """
    Ты — ассистент «второго мозга» пользователя: помогаешь думать, искать и \
    структурировать знания. Отвечай по существу, на языке вопроса.
    """

    /// Инструкция /help-хода: отвечать о проекте по докам, уточнять инструментами.
    static let projectDocsDirective = """
    Ниже — документация проекта пользователя (может быть фрагментами). Отвечай \
    на вопрос по ней; используй её как контекст, не упоминай существование \
    этого блока. Если сведений не хватает, уточняй деталями через доступные \
    инструменты (git_branches, git_status, git_log, git_diff, list_files, read_file).
    """

    /// Директива tool-режима RAG (задача 34): модель обязана искать в базах,
    /// а не отвечать из общих знаний, когда вопрос про заметки пользователя.
    static let ragToolDirective = """
    Доступен инструмент rag_search — семантический поиск по базам знаний \
    пользователя. Если вопрос касается заметок, встреч, документации или любых \
    личных фактов пользователя — СНАЧАЛА поищи через rag_search (можно несколько \
    раз с разными формулировками и базами), потом отвечай по найденному, ссылаясь \
    на заметки в формате [[Имя заметки]]. Если поиск ничего не дал — честно скажи, \
    что в базе знаний ответа нет.
    """

    /// Директива файловых инструментов (задача 39): что доступно, где корень
    /// и как вести себя в текущем режиме разрешений. Отклонение операции
    /// пользователем — не сбой: модель продолжает без неё или уточняет.
    static func fileToolsDirective(mode: AgentPermissionMode, rootPath: String) -> String {
        var lines = ["""
        Тебе доступны файловые инструменты проекта: search_files (поиск по \
        содержимому), read_file, list_files, write_file (создать/перезаписать), \
        edit_file (точечная правка old_string → new_string), delete_file \
        (в Корзину), run_command (shell в корне проекта) и git-обзор \
        (git_status/git_log/git_diff/git_branches). Рабочий корень: \(rootPath). \
        Все пути указывай ОТНОСИТЕЛЬНО корня. Перед write_file/edit_file \
        существующего файла обязательно прочитай его через read_file.
        """]
        switch mode {
        case .ask:
            lines.append("""
            Режим «Спрашивать»: правки и опасные операции показываются \
            пользователю на подтверждение. Отказ пользователя (ERROR: \
            «пользователь отклонил…») — не сбой: продолжай без этой операции \
            или уточни, чего он хочет.
            """)
        case .auto:
            lines.append("""
            Режим «Авто»: правки файлов применяются сразу — в финальном ответе \
            перечисли изменённые файлы и суть правок. Опасные операции \
            (удаление, произвольные команды) запросят подтверждение; отказ — \
            не сбой, продолжай без операции.
            """)
        case .autoDanger:
            lines.append("""
            Режим «Авто-опасный»: все операции выполняются без подтверждений. \
            Будь консервативен: не удаляй и не переписывай лишнего, в финальном \
            ответе перечисли все изменения.
            """)
        }
        return lines.joined(separator: "\n")
    }

    /// Собирает системный промпт из базы и опциональных секций.
    static func systemPrompt(ragContext: String? = nil,
                             projectDocs: String? = nil,
                             tools: String? = nil) -> String {
        var parts = [basePrompt]
        if let ragContext, !ragContext.isEmpty {
            parts.append("[RAG_CONTEXT]\n\(ragContext)")
        }
        if let projectDocs, !projectDocs.isEmpty {
            parts.append("[PROJECT_DOCS]\n\(projectDocsDirective)\n\n\(projectDocs)")
        }
        if let tools, !tools.isEmpty {
            parts.append("[TOOLS]\n\(tools)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Сообщения для API: системный промпт + окно последних N сообщений истории.
    /// История отправляется целиком в каждом запросе (API stateless — как в MA).
    static func requestMessages(history: [ChatMessage],
                                historyWindow: Int,
                                ragContext: String? = nil,
                                projectDocs: String? = nil,
                                tools: String? = nil) -> [ChatMessageDTO] {
        var messages = [ChatMessageDTO(role: .system,
                                       content: systemPrompt(ragContext: ragContext,
                                                             projectDocs: projectDocs,
                                                             tools: tools))]
        let window = history.suffix(max(1, historyWindow))
        messages.append(contentsOf: window.compactMap { message in
            let role: ChatMessageDTO.Role
            switch message.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .assistant
            }
            // Пустые сообщения (недописанные заглушки) в API не уходят.
            guard !message.content.isEmpty else { return nil }
            return ChatMessageDTO(role: role, content: message.content)
        })
        return messages
    }
}
