// BacklinksView.swift — панель обратных ссылок под редактором.
//
// Показывает, какие заметки ссылаются на открытую: имя источника + строка-
// сниппет с [[ссылкой]]. Клик открывает заметку-источник. Данные приходят из
// LinkIndex (VaultManager.linkIndex), перезапрашиваются по linkVersion.

import SwiftUI

/// Сворачиваемая панель backlinks для открытой заметки.
struct BacklinksView: View {
    /// Заметка, для которой ищем входящие ссылки.
    let url: URL
    @ObservedObject var vaultManager: VaultManager
    @State private var isExpanded = true

    /// linkVersion в зависимостях body: пересчёт при каждом обновлении индекса.
    private var backlinks: [LinkOccurrence] {
        _ = vaultManager.linkVersion
        return vaultManager.linkIndex?.backlinks(to: url) ?? []
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if backlinks.isEmpty {
                Text("На эту заметку пока никто не ссылается.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(backlinks.enumerated()), id: \.offset) { _, occurrence in
                            backlinkRow(occurrence)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        } label: {
            Label("Обратные ссылки (\(backlinks.count))", systemImage: "arrow.turn.up.left")
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Строка панели: источник + сниппет; клик открывает источник.
    private func backlinkRow(_ occurrence: LinkOccurrence) -> some View {
        Button {
            vaultManager.open(occurrence.sourceFile)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.sourceFile.deletingPathExtension().lastPathComponent)
                    .font(.callout.weight(.semibold))
                Text(occurrence.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
