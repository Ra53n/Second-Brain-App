// TurnOverrides.swift — переопределения одного хода отправки (задача 22, вынесено в 76).

import Foundation

extension ChatViewModel {
    /// Переопределения одного хода (задача 22): /help добавляет докблок,
    /// принудительно включает инструменты проекта и пропускает RAG.
    /// Было `private` внутри ChatViewModel — здесь минимум `internal`
    /// (Swift не даёт `private` через границу файла для пользователей в
    /// ChatViewModel.swift; наблюдаемое поведение не меняется).
    struct TurnOverrides {
        /// Загрузить [PROJECT_DOCS] через projectDocsProvider.
        var wantsProjectDocs = false
        /// Инструменты проекта включаются независимо от настройки чата.
        var forceProjectTools = false
        /// RAG-ретрив пропускается (докблок заменяет его на этом ходу).
        var skipsRag = false
        /// Провайдер без function calling → ответ без инструментов, не ошибка.
        var allowsToolFallback = false
    }
}
