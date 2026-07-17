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
