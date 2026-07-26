// ChatGitBridge.swift — мост ChatViewModel к git-каталогу чата (задача 40, вынесено в 76).

import Foundation

extension ChatViewModel {
    /// Мост вкладки «Изменения» к git-каталогу чата (задача 40): обзор
    /// (ветка/статус/diff), коммит и пуш. Первый параметр — projectRootPath
    /// чата (nil = глобальная настройка). commit/push возвращают текст
    /// ошибки; nil — успех.
    struct ChatGitBridge {
        var overview: (String?) async -> GitChangesOverview?
        var commit: (String?, String) async -> String?
        var push: (String?) async -> String?
        /// Точечный откат одного файла: tracked → к HEAD, новый → в Корзину.
        var revertFile: (String?, String) async -> String?
    }
}
