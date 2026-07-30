// FineTuneCheckpointPicker.swift — выбор чекпоинта по минимуму val loss (P1, без I/O).
//
// На малых датасетах train loss продолжает падать после начала переобучения —
// финальный адаптер почти никогда не лучший, выбирать нужно по val loss.

import Foundation

enum FineTuneCheckpointPicker {
    struct Pick: Equatable {
        let iter: Int
        let valLoss: Double
        let lastValLoss: Double
        let isOverfit: Bool
        let fileName: String
    }

    /// Минимум val loss; при равенстве выигрывает более ранняя итерация (как
    /// `min(points, key=...)` в python — первый найденный элемент при ничьей).
    /// `last` — последняя точка в исходном (хронологическом) порядке; для поиска
    /// минимума точки явно сортируются по iter — так «раньше» не зависит от
    /// порядка на входе, и строгого `<` достаточно, без отдельной ветки на ничью.
    static func best(from points: [FineTuneProgressPoint]) -> Pick? {
        let valPoints = points.filter { $0.kind == .val }
        guard let last = valPoints.last else { return nil }

        var best: FineTuneProgressPoint?
        for point in valPoints.sorted(by: { $0.iter < $1.iter }) {
            guard let current = best else { best = point; continue }
            if point.loss < current.loss { best = point }
        }
        guard let bestPoint = best else { return nil }

        return Pick(iter: bestPoint.iter, valLoss: bestPoint.loss, lastValLoss: last.loss,
                    isOverfit: last.loss > bestPoint.loss,
                    fileName: String(format: "%07d_adapters.safetensors", bestPoint.iter))
    }
}
