// ContentView.swift — корневой экран: NavigationSplitView с сайдбаром разделов.
//
// Каркас (задача 01): разделы — заглушки; каждый оживёт в своей задаче
// (Заметки — 02/03, Встречи — 11, Чат — 12, Настройки — 17). Detail-область
// показывает плейсхолдер, чтобы окно не выглядело сломанным.

import SwiftUI

/// Разделы приложения в сайдбаре. Порядок фиксирован — как в VISION.md.
enum AppSection: String, CaseIterable, Identifiable {
    case notes = "Заметки"
    case meetings = "Встречи"
    case chat = "Чат"
    case settings = "Настройки"

    var id: String { rawValue }

    /// SF-символ раздела для сайдбара.
    var systemImage: String {
        switch self {
        case .notes: return "doc.text"
        case .meetings: return "mic"
        case .chat: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }

    /// Номер задачи из tasks/, в которой раздел получит содержимое.
    var plannedTask: String {
        switch self {
        case .notes: return "02–05"
        case .meetings: return "06, 11"
        case .chat: return "12–14"
        case .settings: return "17"
        }
    }
}

/// Корневой view: сайдбар разделов + detail-плейсхолдер.
struct ContentView: View {
    @State private var selection: AppSection? = .notes

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .frame(minWidth: 220)
        } detail: {
            detailPlaceholder
                .frame(minWidth: 480, minHeight: 600)
        }
    }

    /// Плейсхолдер detail-области: говорит, в какой задаче раздел оживёт.
    @ViewBuilder
    private var detailPlaceholder: some View {
        if let section = selection {
            ContentUnavailableView {
                Label(section.rawValue, systemImage: section.systemImage)
            } description: {
                Text("Раздел появится в задаче \(section.plannedTask).")
            }
        } else {
            ContentUnavailableView(
                "Выберите раздел",
                systemImage: "sidebar.left",
                description: Text("Разделы — в сайдбаре слева.")
            )
        }
    }
}
