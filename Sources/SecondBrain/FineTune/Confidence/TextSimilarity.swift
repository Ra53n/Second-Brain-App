// TextSimilarity.swift — порт difflib.SequenceMatcher.ratio() (задача 85).

import Foundation

enum TextSimilarity {

    /// Ratcliff/Obershelp с autojunk python по умолчанию (`isjunk=None`, `autojunk=True`):
    /// склейка нормализованных `task` в `ConfidenceChecks` на длинных фрагментах реально
    /// достигает 300+ символов (`finetune/meetings/data/valid.jsonl`: 8 из 116 примеров
    /// ≥ 200), где autojunk меняет результат — эвристика обязательна для совпадения с python.
    static func ratio(_ a: String, _ b: String) -> Double {
        let aChars = Array(a), bChars = Array(b)
        let length = aChars.count + bChars.count
        guard length > 0 else { return 1.0 }
        let matches = matchingBlocks(aChars, bChars).reduce(0) { $0 + $1.size }
        return 2.0 * Double(matches) / Double(length)
    }

    private struct Match: Comparable {
        let a: Int
        let b: Int
        let size: Int

        static func < (lhs: Match, rhs: Match) -> Bool {
            (lhs.a, lhs.b, lhs.size) < (rhs.a, rhs.b, rhs.size)
        }
    }

    private static func findLongestMatch(_ a: [Character], _ b: [Character],
                                          _ b2j: [Character: [Int]],
                                          alo: Int, ahi: Int, blo: Int, bhi: Int) -> Match {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            if let indices = b2j[a[i]] {
                for j in indices {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    newj2len[j] = k
                    if k > bestsize {
                        besti = i - k + 1
                        bestj = j - k + 1
                        bestsize = k
                    }
                }
            }
            j2len = newj2len
        }
        while besti > alo, bestj > blo, a[besti - 1] == b[bestj - 1] {
            besti -= 1; bestj -= 1; bestsize += 1
        }
        while besti + bestsize < ahi, bestj + bestsize < bhi, a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return Match(a: besti, b: bestj, size: bestsize)
    }

    private static func matchingBlocks(_ a: [Character], _ b: [Character]) -> [Match] {
        var b2j: [Character: [Int]] = [:]
        for (index, char) in b.enumerated() { b2j[char, default: []].append(index) }

        // autojunk (CPython `__chain_b`): при len(b) ≥ 200 элемент, встречающийся в b
        // чаще len(b)//100+1 раз, считается «популярным» и убирается из b2j целиком — не
        // может стать затравкой нового совпадения (но расширение уже найденного через
        // такой символ не блокируется — python здесь смотрит на `bjunk`, который у нас,
        // как и у python без `isjunk`, всегда пуст).
        if b.count >= 200 {
            let threshold = b.count / 100 + 1
            let popular = b2j.filter { $0.value.count > threshold }.keys
            for char in popular { b2j.removeValue(forKey: char) }
        }

        var queue: [(alo: Int, ahi: Int, blo: Int, bhi: Int)] = [(0, a.count, 0, b.count)]
        var blocks: [Match] = []
        while let region = queue.popLast() {
            let match = findLongestMatch(a, b, b2j, alo: region.alo, ahi: region.ahi,
                                          blo: region.blo, bhi: region.bhi)
            guard match.size > 0 else { continue }
            blocks.append(match)
            if region.alo < match.a, region.blo < match.b {
                queue.append((region.alo, match.a, region.blo, match.b))
            }
            if match.a + match.size < region.ahi, match.b + match.size < region.bhi {
                queue.append((match.a + match.size, region.ahi, match.b + match.size, region.bhi))
            }
        }
        blocks.sort()

        var merged: [Match] = []
        var i1 = 0, j1 = 0, k1 = 0
        for block in blocks {
            if i1 + k1 == block.a, j1 + k1 == block.b {
                k1 += block.size
            } else {
                if k1 > 0 { merged.append(Match(a: i1, b: j1, size: k1)) }
                i1 = block.a; j1 = block.b; k1 = block.size
            }
        }
        if k1 > 0 { merged.append(Match(a: i1, b: j1, size: k1)) }
        return merged
    }
}
