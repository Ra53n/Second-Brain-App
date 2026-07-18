// ToolApprovalCenter.swift — подтверждение операций инструментов (задача 39).
//
// Гейт в ChatToolAssembly классифицирует каждый вызов (ToolPermissions);
// когда режим чата требует подтверждения — сюда публикуется PendingToolApproval,
// tool-цикл ЖДЁТ решения пользователя на CheckedContinuation (провайдерских
// таймаутов между итерациями нет — LLM-запрос уже завершён). Кнопки карточки:
// «Разрешить» (один раз) / «На сессию» (ключ операции в allowlist до
// перезапуска приложения) / «Отклонить» (модель получает ERROR и реагирует).
//
// Отмена хода/паузы FSM гасит ожидание через cancellation handler — deny.
// Выход из приложения прерывает ход целиком (семантика FSM running → paused).

import Foundation

/// Решение пользователя по операции.
enum ToolApprovalDecision: Sendable {
    case allowOnce, allowSession, deny
}

/// Ожидающий подтверждения вызов инструмента — карточка над полем ввода.
struct PendingToolApproval: Identifiable, Equatable {
    let id: UUID
    let chatID: UUID
    let toolName: String
    let risk: ToolRiskLevel
    /// Детали операции: unified diff правки, команда shell, путь удаления
    /// либо JSON аргументов (MCP).
    let detail: String
}

extension ChatViewModel {
    // MARK: - Ожидание решения

    /// Публикует запрос и ждёт решения пользователя. Отмена родительского
    /// Task (стоп генерации, пауза FSM, удаление чата) → deny.
    func requestToolApproval(chatID: UUID, toolName: String,
                             risk: ToolRiskLevel, detail: String) async -> ToolApprovalDecision {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approvalContinuations[id] = continuation
                pendingToolApprovals.append(PendingToolApproval(
                    id: id, chatID: chatID, toolName: toolName,
                    risk: risk, detail: detail))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveToolApproval(id: id, decision: .deny)
            }
        }
    }

    /// Решение по карточке (кнопки UI и cancellation handler). Идемпотентен:
    /// continuation резюмится ровно один раз (removeValue — гард).
    func resolveToolApproval(id: UUID, decision: ToolApprovalDecision) {
        pendingToolApprovals.removeAll { $0.id == id }
        guard let continuation = approvalContinuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: decision)
    }

    /// Deny всем ожиданиям чата (удаление чата).
    func denyPendingApprovals(chatID: UUID) {
        for approval in pendingToolApprovals where approval.chatID == chatID {
            resolveToolApproval(id: approval.id, decision: .deny)
        }
    }

    // MARK: - Сессионный allowlist («Разрешить на сессию»)

    /// Ключ операции одобрен на сессию (in-memory, до перезапуска приложения).
    func isSessionApproved(chatID: UUID, key: String) -> Bool {
        sessionApprovals[chatID]?.contains(key) ?? false
    }

    func addSessionApproval(chatID: UUID, key: String) {
        sessionApprovals[chatID, default: []].insert(key)
    }

    // MARK: - Контекст файловых операций

    /// Контекст файловых операций чата (реестр чтений + изменения хода).
    func fileOps(for chatID: UUID) -> FileOpsContext {
        if let existing = fileOpsContexts[chatID] { return existing }
        let context = FileOpsContext()
        fileOpsContexts[chatID] = context
        return context
    }

    // MARK: - Настройки чата (задача 39)

    /// Режим разрешений текущего чата (persisted per-чат).
    var permissionModeBinding: AgentPermissionMode {
        get { selectedChat?.configuration.permissionMode ?? .ask }
        set {
            guard let index = chats.firstIndex(where: { $0.id == selectedChatID }) else { return }
            chats[index].configuration.permissionMode = newValue
        }
    }

    /// Рабочий каталог текущего чата; nil — глобальная настройка.
    var chatProjectRootPath: String? {
        selectedChat?.configuration.projectRootPath
    }

    func setChatProjectRoot(_ path: String?) {
        guard let index = chats.firstIndex(where: { $0.id == selectedChatID }) else { return }
        chats[index].configuration.projectRootPath = path
    }

    /// «Сделать базой знаний» (задача 39): каталог чата → папочная база
    /// реестра (задача 34) + включение в этом чате. Мост addFolderKnowledgeBase
    /// подвязывает AppModel. Возвращает имя базы; nil — каталог не задан.
    @discardableResult
    func makeKnowledgeBaseFromChatRoot() -> String? {
        guard let index = chats.firstIndex(where: { $0.id == selectedChatID }),
              let root = projectToolsBridge?.rootURL(
                chats[index].configuration.projectRootPath),
              let baseID = addFolderKnowledgeBase?(root), !baseID.isEmpty else { return nil }
        chats[index].configuration.enabledKnowledgeBaseIDs.insert(baseID)
        chats[index].configuration.ragEnabled = true
        return baseID
    }

    /// Компактные аргументы вызова для карточки approve (MCP и фолбэк).
    static func compactArguments(_ argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return "(без аргументов)" }
        return trimmed.count > 2048 ? String(trimmed.prefix(2048)) + "…" : trimmed
    }
}
