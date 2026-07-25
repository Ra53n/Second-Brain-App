// RagVectorTests.swift — тесты векторной математики RAG (задача 58).
//
// Покрыто: dot/norm/normalize по границам длины и нулевому вектору; cosine на
// сонаправленных/ортогональных/противоположных/разной длины/NaN/Inf входах;
// topK на k>count, k<=0, пустой матрице, равных score (устойчивость сортировки),
// большой матрице, NaN-score во входе.

import XCTest
@testable import SecondBrain

/// Покомпонентное сравнение с точностью — для [Float], где точного XCTAssertEqual
/// с accuracy для массивов в XCTest нет.
private func assertVectorEqual(_ a: [Float], _ b: [Float], accuracy: Float,
                                file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "разная длина векторов", file: file, line: line)
    for (x, y) in zip(a, b) {
        XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line)
    }
}

final class VectorDotNormTests: XCTestCase {

    func testDotOfEqualLengthVectors() {
        XCTAssertEqual(Vector.dot([1, 2, 3], [4, 5, 6]), 32)
    }

    /// «Разная длина векторов» — dot считает только по min(a.count, b.count).
    func testDotUsesMinimumLengthWhenVectorsDiffer() {
        XCTAssertEqual(Vector.dot([1, 2], [1, 2, 3]), 5, "a короче b")
        XCTAssertEqual(Vector.dot([1, 2, 3], [4, 5]), 14, "a длиннее b")
    }

    func testDotOfEmptyVectorsIsZero() {
        XCTAssertEqual(Vector.dot([], []), 0)
        XCTAssertEqual(Vector.dot([], [1, 2, 3]), 0, "пустой + непустой — по min длине 0")
    }

    func testNormComputesEuclideanLength() {
        XCTAssertEqual(Vector.norm([3, 4]), 5, accuracy: 1e-5)
    }

    func testNormOfEmptyOrZeroVectorIsZero() {
        XCTAssertEqual(Vector.norm([]), 0)
        XCTAssertEqual(Vector.norm([0, 0, 0]), 0)
    }

    func testNormalizeProducesUnitVector() {
        assertVectorEqual(Vector.normalize([3, 4]), [0.6, 0.8], accuracy: 1e-5)
    }

    /// Нулевой вектор остаётся нулевым и неизменным как значение — деления на
    /// норму=0 не происходит (норма гарда).
    func testNormalizeOfZeroVectorReturnsInputUnchanged() {
        XCTAssertEqual(Vector.normalize([0, 0, 0]), [0, 0, 0])
    }

    func testNormalizeOfEmptyVectorReturnsEmpty() {
        XCTAssertEqual(Vector.normalize([]), [])
    }

    func testNormalizeOfAlreadyUnitVectorIsStable() {
        let unit = Vector.normalize([1, 0, 0])
        XCTAssertEqual(Vector.normalize(unit), unit)
    }
}

final class VectorCosineTests: XCTestCase {

    func testCosineOfParallelVectorsIsOne() {
        XCTAssertEqual(Vector.cosine([1, 2, 3], [2, 4, 6]), 1, accuracy: 1e-4, "b = 2*a — сонаправлены")
    }

    func testCosineOfOrthogonalVectorsIsZero() {
        XCTAssertEqual(Vector.cosine([1, 0], [0, 1]), 0)
    }

    func testCosineOfOppositeVectorsIsMinusOne() {
        XCTAssertEqual(Vector.cosine([1, 0], [-1, 0]), -1)
    }

    func testCosineWithZeroVectorIsZeroNotNaN() {
        XCTAssertEqual(Vector.cosine([0, 0, 0], [1, 2, 3]), 0)
        XCTAssertEqual(Vector.cosine([1, 2, 3], [0, 0, 0]), 0)
        XCTAssertEqual(Vector.cosine([], []), 0, "оба пустые — норма 0 с обеих сторон")
    }

    /// dot считает по min-длине, но norm(a)/norm(b) — по полной длине каждого
    /// вектора: результат не совпадает с «наивным» cosine по общей длине.
    /// Проверено численно: 5/sqrt(70) ≈ 0.597614.
    func testCosineWithDifferentLengthVectors() {
        XCTAssertEqual(Vector.cosine([1, 2, 3], [1, 2]), 0.597614, accuracy: 1e-4)
    }

    /// NaN в компоненте → norm тоже NaN → «guard na > 0» ложно для NaN
    /// (сравнения с NaN всегда false) → безопасный откат к 0, без падения.
    func testCosineWithNaNComponentFallsBackToZero() {
        XCTAssertEqual(Vector.cosine([Float.nan, 1], [1, 1]), 0)
        XCTAssertEqual(Vector.cosine([1, 1], [Float.nan, 1]), 0)
    }

    /// НАХОДКА: Infinity в компоненте идёт другим путём, чем NaN. norm(a) тоже
    /// становится Infinity (Infinity > 0 истинно, guard проходит), а
    /// dot(a,b)/(∞·finite) = ∞, и итоговое ∞/∞ по IEEE 754 — NaN, а не 0.
    /// Комментарий функции обещает диапазон «в [-1, 1]» — для Infinity это не так,
    /// защиты, симметричной NaN-случаю, здесь нет.
    func testCosineWithInfiniteComponentProducesNaNNotZero() {
        let result = Vector.cosine([Float.infinity, 1], [1, 1])
        XCTAssertTrue(result.isNaN, "фактическое поведение: ∞/∞ = NaN, вопреки диапазону [-1,1] из комментария")
    }
}

final class VectorTopKTests: XCTestCase {

    /// Общая матрица с заведомо различными score: query=[1,0], индексы дают
    /// score 1.0, ~0.7071, 0.0, -1.0 соответственно.
    private let query: [Float] = [1, 0]
    private let matrix: [[Float]] = [[0, 1], [1, 0], [-1, 0], [1, 1]]

    func testTopKOrdersDescendingByScore() {
        let result = Vector.topK(query: query, matrix: matrix, k: 4)
        XCTAssertEqual(result.map(\.index), [1, 3, 0, 2])
        assertVectorEqual(result.map(\.score), [1, 0.70711, 0, -1], accuracy: 1e-4)
    }

    func testTopKReturnsAllWhenKExceedsCount() {
        let result = Vector.topK(query: query, matrix: matrix, k: matrix.count + 1)
        XCTAssertEqual(result.count, matrix.count, "лимит+1 не даёт больше элементов, чем есть")
    }

    func testTopKReturnsExactlyLimitWhenKEqualsCount() {
        let result = Vector.topK(query: query, matrix: matrix, k: matrix.count)
        XCTAssertEqual(result.count, matrix.count)
    }

    func testTopKWithNonPositiveKReturnsEmpty() {
        for k in [0, -1, -100] {
            XCTAssertTrue(Vector.topK(query: query, matrix: matrix, k: k).isEmpty, "k=\(k)")
        }
    }

    func testTopKOnEmptyMatrixReturnsEmpty() {
        XCTAssertTrue(Vector.topK(query: query, matrix: [], k: 5).isEmpty)
        // k<=0 и пустая матрица одновременно — тоже пусто, не падает.
        XCTAssertTrue(Vector.topK(query: query, matrix: [], k: 0).isEmpty)
    }

    /// Равные score → порядок должен быть детерминированным. sorted() в Swift
    /// с 5-й версии гарантированно стабилен: при равенстве компаратора исходный
    /// порядок (по индексу в matrix) сохраняется.
    func testTopKIsStableForEqualScores() {
        let tiedMatrix: [[Float]] = [[2, 0], [3, 0], [4, 0]] // все сонаправлены с query → cosine=1 у всех трёх
        let result = Vector.topK(query: query, matrix: tiedMatrix, k: 3)
        XCTAssertEqual(result.map(\.index), [0, 1, 2])
    }

    /// Большая матрица (2000 векторов): единственный вектор с cosine=1 —
    /// подтверждает, что brute-force реализация находит верный максимум и не
    /// путается на масштабе, близком к реальному vault.
    func testTopKOnLargeMatrixFindsUniqueClosestVector() {
        let count = 2000
        let target = 1234
        let bigMatrix: [[Float]] = (0..<count).map { [1, Float($0 - target)] }
        let bigQuery: [Float] = [1, 0]

        let result = Vector.topK(query: bigQuery, matrix: bigMatrix, k: 5)

        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0].index, target)
        XCTAssertEqual(result[0].score, 1, accuracy: 1e-5)
        for i in 1..<result.count {
            XCTAssertLessThanOrEqual(result[i].score, result[i - 1].score, "убывание по score, позиция \(i)")
        }
    }

    /// Вектор с Infinity даёт NaN-score (см. VectorCosineTests) — topK не должен
    /// падать и не должен терять элементы из-за непредсказуемого сравнения с NaN;
    /// порядок именно NaN-элемента не гарантирован и не проверяется.
    func testTopKDoesNotLoseElementsWhenScoreIsNaN() {
        let matrixWithNaN: [[Float]] = [[1, 0], [Float.infinity, 1], [-1, 0]]
        let result = Vector.topK(query: query, matrix: matrixWithNaN, k: 3)

        XCTAssertEqual(result.count, 3, "NaN-score не должен приводить к потере элементов")
        XCTAssertEqual(Set(result.map(\.index)), Set([0, 1, 2]))
    }
}
