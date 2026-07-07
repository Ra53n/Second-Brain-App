// VaultScanner.swift — обход vault: список .md-файлов без dot-папок.
//
// Общий примитив для всех индексов (LinkIndex — задача 04, SearchIndex — 05,
// RAG — 13): один и тот же обход, чтобы «что считается заметкой» не разъезжалось
// между подсистемами. Dot-папки (.obsidian, .git, .trash) отсекаются целиком.

import Foundation

enum VaultScanner {

    /// Все .md-файлы vault (рекурсивно), стандартизованные URL.
    /// Симлинки не разыменовываются — защита от циклов.
    static func markdownFiles(in root: URL) -> [URL] {
        var result: [URL] = []
        func walk(_ dir: URL) {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
            )) ?? []
            for url in entries {
                if url.lastPathComponent.hasPrefix(".") { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    walk(url)
                } else if url.pathExtension.lowercased() == "md" {
                    result.append(url.standardizedFileURL)
                }
            }
        }
        walk(root)
        return result
    }

    /// mtime файла; nil, если файл исчез.
    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
