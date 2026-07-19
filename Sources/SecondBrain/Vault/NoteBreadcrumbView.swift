// NoteBreadcrumbView.swift — путь открытой заметки и содержимое папки (задача 42).
//
// Здесь живут:
//  - NoteBreadcrumbBar  — полоска пути над detail-панелью раздела «Заметки»
//                         (стиль Obsidian/Finder): сегменты от корня vault до
//                         открытого файла, клик по сегменту открывает папку
//                         и раскрывает её в дереве (VaultManager.open);
//  - FolderContentsView — detail-панель папки: список содержимого, клик
//                         открывает элемент (файл — редактор, папку — снова
//                         этот же список; вместе с breadcrumb получается
//                         навигация вверх/вниз, как по колонке Finder).
//
// View только читают VaultManager и зовут open(_:) — вся логика там.

import SwiftUI

/// Полоска пути (breadcrumb) для выбранного узла vault.
struct NoteBreadcrumbBar: View {
    let node: VaultNode
    @ObservedObject var manager: VaultManager

    /// Сегменты пути; пусто, если vault закрыт или узел вне vault
    /// (полоска тогда не рисуется — см. ContentView).
    private var segments: [PathSegment] {
        guard let vaultURL = manager.vaultURL else { return [] }
        return VaultPath.segments(for: node.url, isDirectory: node.isDirectory, vaultRoot: vaultURL) ?? []
    }

    var body: some View {
        let segments = segments
        if !segments.isEmpty {
            // Горизонтальный скролл с якорем к хвосту: у глубоких путей всегда
            // видны имя файла и ближайшие папки, начало доскролливается.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        segmentButton(segment, isLast: index == segments.count - 1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .defaultScrollAnchor(.trailing)
        }
    }

    /// Сегмент пути: клик открывает узел (папку — списком, файл — редактором).
    /// Последний сегмент — «мы здесь», выделен цветом, но тоже кликабелен
    /// (повторный клик доскроллит дерево к текущему файлу).
    private func segmentButton(_ segment: PathSegment, isLast: Bool) -> some View {
        Button {
            manager.open(segment.url)
        } label: {
            Label(
                segment.name,
                systemImage: VaultNode.systemImage(
                    isDirectory: segment.isDirectory,
                    fileExtension: segment.url.pathExtension
                )
            )
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(isLast ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(isLast ? "Показать в дереве" : "Открыть папку «\(segment.name)»")
    }
}

/// Detail-панель папки: содержимое в один клик.
struct FolderContentsView: View {
    let node: VaultNode
    @ObservedObject var manager: VaultManager

    var body: some View {
        if let children = node.children, !children.isEmpty {
            List(children) { child in
                Button {
                    manager.open(child.url)
                } label: {
                    Label(child.name, systemImage: child.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            ContentUnavailableView(
                "Папка пуста",
                systemImage: "folder",
                description: Text("Создайте заметку через контекстное меню дерева.")
            )
        }
    }
}
