// ReviewPostContext.swift — контекст диалога постинга code review (вынесено в 76).

import Foundation

extension ChatViewModel {
    /// Диалог превью постинга ревью в PR (item-based sheet, паттерн
    /// titleDialog встреч). non-nil → шит открыт.
    struct ReviewPostContext: Identifiable {
        let messageID: UUID
        let target: ReviewTarget
        /// Предзаполненный текст комментария (content сообщения), редактируемый.
        var body: String
        var id: UUID { messageID }
    }
}
