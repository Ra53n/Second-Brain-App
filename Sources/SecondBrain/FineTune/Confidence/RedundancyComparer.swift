// RedundancyComparer.swift — согласие N повторных прогонов (задача 85).

import Foundation

enum RedundancyAgreement: String, Codable {
    case agree, partial, disagree

    /// Синтезированный декодер `RawRepresentable` бросает на незнакомой строке — тот же
    /// баг, что был у `ConfidenceVerdict` (см. `ConfidenceVerdict.init(from:)` и
    /// `ConfidenceVerdictDecodeRegressionTests`): один элемент с «значением из будущего»
    /// карантинил весь `finetune-chat.json`. Незнакомое → `.disagree`, а не `.agree`/
    /// `.partial` — неизвестный сигнал согласия не должен молча повышать уверенность вердикта.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RedundancyAgreement(rawValue: raw) ?? .disagree
    }
}

enum RedundancyComparer {

    /// Все ответы попарно совпали → agree; существует большинство (⌊N/2⌋+1, для N=3 —
    /// минимум 2), взаимно попарно совпадающее → partial; иначе disagree.
    static func compare(_ answers: [[ActionItem]]) -> RedundancyAgreement {
        let n = answers.count
        guard n > 1 else { return .agree }

        var matches = Array(repeating: Array(repeating: false, count: n), count: n)
        for i in 0..<n {
            matches[i][i] = true
            for j in (i + 1)..<n {
                let match = pairwiseMatch(answers[i], answers[j])
                matches[i][j] = match
                matches[j][i] = match
            }
        }

        let all = Array(0..<n)
        if isClique(all, matches) { return .agree }
        let majoritySize = n / 2 + 1
        return hasClique(ofSize: majoritySize, among: all, matches: matches) ? .partial : .disagree
    }

    private static func isClique(_ subset: [Int], _ matches: [[Bool]]) -> Bool {
        for i in 0..<subset.count {
            for j in (i + 1)..<subset.count where !matches[subset[i]][subset[j]] {
                return false
            }
        }
        return true
    }

    private static func hasClique(ofSize size: Int, among indices: [Int], matches: [[Bool]]) -> Bool {
        guard size <= indices.count, size > 0 else { return false }
        return combinations(indices, size).contains { isClique($0, matches) }
    }

    private static func combinations(_ elements: [Int], _ k: Int) -> [[Int]] {
        guard k > 0 else { return [[]] }
        guard elements.count >= k else { return [] }
        if k == elements.count { return [elements] }
        let first = elements[0]
        let rest = Array(elements.dropFirst())
        return combinations(rest, k - 1).map { [first] + $0 } + combinations(rest, k)
    }

    /// Два ответа «совпали»: полное паросочетание элементов по assignee/due (нормализовано,
    /// nil==nil) и task (точное совпадение или похожесть ≥ 0.8).
    private static func pairwiseMatch(_ a: [ActionItem], _ b: [ActionItem]) -> Bool {
        guard a.count == b.count else { return false }
        guard !a.isEmpty else { return true }

        func compatible(_ x: ActionItem, _ y: ActionItem) -> Bool {
            guard ActionItemsParser.normalize(x.assignee) == ActionItemsParser.normalize(y.assignee) else { return false }
            guard ActionItemsParser.normalize(x.due) == ActionItemsParser.normalize(y.due) else { return false }
            let taskX = ActionItemsParser.normalize(x.task), taskY = ActionItemsParser.normalize(y.task)
            return taskX == taskY || TextSimilarity.ratio(taskX, taskY) >= 0.8
        }

        var matchB = Array(repeating: -1, count: b.count)
        func augment(_ u: Int, _ visited: inout [Bool]) -> Bool {
            for v in 0..<b.count where compatible(a[u], b[v]) && !visited[v] {
                visited[v] = true
                if matchB[v] == -1 || augment(matchB[v], &visited) {
                    matchB[v] = u
                    return true
                }
            }
            return false
        }
        for u in 0..<a.count {
            var visited = Array(repeating: false, count: b.count)
            guard augment(u, &visited) else { return false }
        }
        return true
    }
}
