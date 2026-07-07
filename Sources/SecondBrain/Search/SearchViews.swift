// SearchViews.swift — UI поиска: список результатов и quick switcher (Cmd+P).
//
// Результаты показываются в колонке «Заметки» вместо дерева, пока поле поиска
// не пусто (переключает VaultPane). Quick switcher — sheet с fuzzy-поиском по
// именам заметок: FTS не нужен, имена фильтруются в памяти (подсказка задачи).

import SwiftUI

/// Список результатов полнотекстового поиска со сниппетами FTS5.
struct SearchResultsView: View {
    @ObservedObject var searchViewModel: SearchViewModel

    var body: some View {
        Group {
            if searchViewModel.results.isEmpty {
                ContentUnavailableView(
                    "Ничего не найдено",
                    systemImage: "magnifyingglass",
                    description: Text("Поиск по всем заметкам vault — слова из текста и имён файлов.")
                )
            } else {
                List(Array(searchViewModel.results.enumerated()), id: \.element.path) { _, hit in
                    Button {
                        searchViewModel.open(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title)
                                .font(.callout.weight(.semibold))
                            Text(Self.attributedSnippet(hit.snippet))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if searchViewModel.isIndexing {
                ProgressView("Индексация…")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }

    /// Сниппет FTS5 → AttributedString: совпадения (между \u{1} и \u{2}) жирным.
    static func attributedSnippet(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var isMatch = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            if isMatch {
                piece.font = .callout.weight(.bold)
                piece.foregroundColor = .primary
            }
            result.append(piece)
            buffer = ""
        }

        for char in snippet {
            switch char {
            case Character(SearchIndex.matchStart):
                flush(); isMatch = true
            case Character(SearchIndex.matchEnd):
                flush(); isMatch = false
            default:
                buffer.append(char)
            }
        }
        flush()
        return result
    }
}

/// Quick switcher (Cmd+P): мгновенный переход к заметке по имени.
struct QuickSwitcherView: View {
    @ObservedObject var vaultManager: VaultManager
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    /// Кандидаты — относительные пути без расширения: уникальны и показывают,
    /// где лежит заметка. Снимок дерева на момент открытия switcher'а.
    private var candidates: [String] {
        guard let root = vaultManager.root, let vaultURL = vaultManager.vaultURL else { return [] }
        var paths: [String] = []
        func walk(_ node: VaultNode) {
            for child in node.children ?? [] {
                if child.isDirectory {
                    walk(child)
                } else if child.url.pathExtension.lowercased() == "md" {
                    let full = child.url.deletingPathExtension().path
                    let rootPath = vaultURL.standardizedFileURL.path + "/"
                    paths.append(full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count)) : full)
                }
            }
        }
        walk(root)
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filtered: [String] {
        Array(FuzzyMatch.filter(query.trimmingCharacters(in: .whitespaces), candidates: candidates).prefix(30))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Имя заметки…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { openSelected() }
                .onKeyPress(.downArrow) {
                    selectedIndex = min(selectedIndex + 1, max(filtered.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectedIndex = max(selectedIndex - 1, 0)
                    return .handled
                }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { index, path in
                            Button {
                                selectedIndex = index
                                openSelected()
                            } label: {
                                Text(path)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(index == selectedIndex
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 320)
                .onChange(of: selectedIndex) { _, index in
                    proxy.scrollTo(index)
                }
            }

            // Скрытая кнопка: Esc закрывает sheet.
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .frame(width: 480)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    private func openSelected() {
        guard filtered.indices.contains(selectedIndex),
              let vaultURL = vaultManager.vaultURL else { return }
        let url = vaultURL
            .appendingPathComponent(filtered[selectedIndex])
            .appendingPathExtension("md")
        vaultManager.selection = url.standardizedFileURL
        dismiss()
    }
}
