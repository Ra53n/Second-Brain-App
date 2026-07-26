// RagToolBridge.swift — мост ChatViewModel к rag_search (задача 34, вынесено в 76).

import Foundation

extension ChatViewModel {
    /// Мост rag_search (задача 34): определение инструмента по включённым
    /// базам чата и исполнитель поиска (KnowledgeBaseManager). Отдельно от
    /// ragProvider: тот — статическая подстановка, этот — tool-режим.
    struct RagToolBridge {
        /// nil — включённых баз нет, инструмент не предлагается.
        var definition: (Set<String>) -> ToolDefinition?
        /// (аргументы вызова, включённые базы, topK, minScore) → текст + источники.
        var execute: (String, Set<String>, Int, Double) async -> RagToolOutcome
    }
}
