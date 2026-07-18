// AgentPrompts.swift — промпты и парсеры этапов FSM-прогона (задача 35).
//
// Порт PipelinePrompts из Manager Assistant (без инвариантов/PROFILE/swarm/
// ASK_USER — бэклог 23–26). «Уровень кода»: ЧТО делает модель на каждом этапе,
// задаёт код — системный промпт = роль этапа, user-сообщение = структурный
// блок [STATE]/[CURRENT]/[PLAN]/[DONE]/[QUERY] + Правила.
//
// Управляющие маркеры: NEXT_STEP (шаг выполнен), REPLAN (план непригоден),
// «ВЕРДИКТ: ВЫПОЛНЕНО / НЕ ВЫПОЛНЕНО» (итог Проверки). Парсеры снисходительны:
// мусорный ответ не роняет прогон — бюджеты ретраев ограничивают повторы.

import Foundation

enum AgentPrompts {
    static let nextStepMarker = "NEXT_STEP" // модель сообщает: текущий шаг выполнен
    static let replanMarker   = "REPLAN"    // модель сообщает: план непригоден

    // MARK: - Системные промпты этапов

    /// Роль этапа — системный промпт фазы.
    static func systemPrompt(for state: AgentTaskState) -> String {
        switch state {
        case .planning:
            return """
            Ты — планировщик. По задаче из [QUERY] составь чёткий пошаговый план: \
            пронумерованные шаги (1., 2., 3., …), каждый шаг — одно конкретное \
            действие по сути задачи, без воды. Не выполняй задачу — только спланируй. \
            НЕ добавляй служебных/протокольных шагов (например «заверши ответ строкой …», \
            «выведи маркер») — только содержательные действия. Верни ТОЛЬКО план.
            """
        case .execution:
            return """
            Ты — исполнитель. Выполни ТОЛЬКО текущий шаг [CURRENT] (НЕ весь план сразу). \
            Уже сделанное в [DONE] используй как контекст. Дай полный результат этого \
            шага. Когда шаг выполнен — заверши ответ ОТДЕЛЬНОЙ ПОСЛЕДНЕЙ строкой \
            «\(nextStepMarker)». Если по ходу стало ясно, что план непригоден и нужно \
            перепланировать — вместо этого заверши ответ строкой «\(replanMarker)».
            """
        case .validation:
            return """
            Ты — проверяющий. Сверь сделанное ([DONE]) с планом и исходной задачей \
            ([QUERY]). Перечисли, что выполнено, что нет, и какие есть проблемы. \
            ПОСЛЕДНЕЙ строкой выведи РОВНО одно из двух: «ВЕРДИКТ: ВЫПОЛНЕНО» либо \
            «ВЕРДИКТ: НЕ ВЫПОЛНЕНО».
            """
        case .answer:
            return """
            Сформируй ФИНАЛЬНЫЙ ОТВЕТ на исходную задачу ([QUERY]) — именно его получит \
            пользователь как результат. Опираясь на план и сделанное ([DONE]), дай \
            полный, готовый к использованию ответ ПО СУЩЕСТВУ: само решение (код / \
            текст / вывод) и всю полезную информацию — как работает, важные детали, \
            примеры использования, ограничения. Пиши так, будто отвечаешь на запрос \
            напрямую. КАТЕГОРИЧЕСКИ НЕ описывай процесс/этапы и НЕ пиши мета-фразы \
            вроде «задача выполнена», «всё проверено» — выдай только сам ответ.
            """
        }
    }

    // MARK: - User-сообщение фазы

    /// Компактный контекст ПРЕДЫДУЩЕГО диалога для прогона: последние обмены
    /// «вопрос пользователя → финальный ответ». Сообщения промежуточных этапов
    /// (planning/execution/validation) — шум, не включаются.
    static func dialogContext(messages: [ChatMessage],
                              maxTurns: Int = 6,
                              maxTurnChars: Int = 500) -> String {
        let relevant = messages.filter { m in
            switch m.role {
            case .user: return true
            case .assistant: return m.agentState == nil || m.agentState == .answer
            default: return false
            }
        }
        let recent = relevant.suffix(maxTurns)
        guard !recent.isEmpty else { return "" }
        return recent.map { m in
            let who = m.role == .user ? "Пользователь" : "Ассистент"
            let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(who): \(String(text.prefix(maxTurnChars)))"
        }.joined(separator: "\n")
    }

    /// User-сообщение фазы = структурный блок контекста автомата.
    /// `rag` — уже сформированный блок [RAG_CONTEXT] (или пустая строка).
    static func buildPrompt(query: String, ctx: AgentTaskContext,
                            rag: String = "", dialog: String = "") -> String {
        func numbered(_ items: [String]) -> String {
            items.isEmpty ? "—"
                : items.enumerated().map { "\($0.offset + 1). \($0.element)" }
                       .joined(separator: "\n           ")
        }
        let stepInfo = (ctx.state == .execution && ctx.total > 0)
            ? ", шаг \(ctx.step + 1)/\(ctx.total)" : ""
        var s = """
        [STATE]    \(ctx.state.rawValue)\(stepInfo)
        [CURRENT]  \(ctx.current.isEmpty ? "—" : ctx.current)
        [PLAN]     \(numbered(ctx.plan))
        [DONE]     \(numbered(ctx.done))
        [QUERY]    \(query)

        Правила:
        - Работай только в рамках текущего шага [CURRENT]; не перепрыгивай этапы и шаги.
        - Если текущий шаг выполнен — заверши ответ строкой «\(nextStepMarker)».
        - Если план непригоден — заверши ответ строкой «\(replanMarker)».
        """
        // Контекст диалога: вопросы про сам диалог («какая была цель?») должны
        // отвечаться по диалогу, а не по случайным RAG-фрагментам.
        let dlg = dialog.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dlg.isEmpty {
            s += "\n\n[КОНТЕКСТ ДИАЛОГА — предыдущие сообщения этого чата]\n" + dlg
        }
        let ragBlock = rag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ragBlock.isEmpty { s += "\n\n\(ragBlock)" }
        // Замечания проверки — в повтор выполнения.
        let v = ctx.validationResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if ctx.state == .execution, ctx.executionRetries > 0, !v.isEmpty {
            s += "\n\n[ЗАМЕЧАНИЯ ПРОВЕРКИ — учти при переделке]\n\(v)"
        }
        // Причина перепланирования — в планирование.
        let fb = ctx.planFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if ctx.state == .planning, !fb.isEmpty {
            s += "\n\n[ПРИЧИНА ПЕРЕПЛАНИРОВАНИЯ / ПРАВКИ]\n\(fb)"
        }
        return s
    }

    // MARK: - Парсеры

    /// Текст плана → список шагов: снимает нумерацию/маркеры списка; пустой
    /// результат → весь текст одним шагом. Строки-артефакты с протокольными
    /// маркерами (планировщик включил «заверши строкой NEXT_STEP» как «шаг»)
    /// отбрасываются — после очистки такой шаг невыполним и зациклит проверку.
    static func parsePlanSteps(_ text: String) -> [String] {
        var steps: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let r = line.range(of: #"^\s*(\d+[.)]|[-–•*])\s+"#, options: .regularExpression) {
                line.removeSubrange(r)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            let upper = line.uppercased()
            if upper.contains(nextStepMarker) || upper.contains(replanMarker) { continue }
            if !line.isEmpty { steps.append(line) }
        }
        if steps.isEmpty {
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [whole]
        }
        return steps
    }

    static func wantsNextStep(_ text: String) -> Bool { text.uppercased().contains(nextStepMarker) }
    static func wantsReplan(_ text: String) -> Bool { text.uppercased().contains(replanMarker) }

    /// Убирает служебные маркеры из текста перед показом/сохранением.
    static func stripMarkers(_ text: String) -> String {
        var t = text
        for m in [nextStepMarker, replanMarker] {
            t = t.replacingOccurrences(of: m, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Парсит вердикт Проверки. true = выполнено. Смотрит ПОСЛЕДНИЙ «ВЕРДИКТ:»;
    /// при отсутствии/неоднозначности → true (повторы ограничены лимитом —
    /// лучше двинуться вперёд, чем зациклиться на невнятной проверке).
    static func parseVerdict(_ text: String) -> Bool {
        let upper = text.uppercased()
        if let r = upper.range(of: "ВЕРДИКТ:", options: .backwards) {
            let tail = upper[r.upperBound...]
            if tail.contains("НЕ ВЫПОЛНЕНО") { return false }
            if tail.contains("ВЫПОЛНЕНО") { return true }
        }
        return true
    }
}
