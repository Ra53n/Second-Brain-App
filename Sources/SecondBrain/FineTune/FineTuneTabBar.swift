// FineTuneTabBar.swift — вкладки датасета в разделе «Тюнинг» (задача 83).
//
// Кастомные plain-кнопки в HStack, а не Picker(.segmented): сегменты Picker на
// macOS не отдают Accessibility-подпись вообще (проверено эмпирически в задаче 81),
// а смоук ./scripts/ui.sh работает только через AX. Активная вкладка подсвечена
// фоном и тинтом — прежний вариант (кнопки тулбара с .fontWeight) визуально не
// читался. accessibilityValue "выбрано" даёт смоуку способ ассертить активную вкладку.

import SwiftUI

/// Вкладки detail-экрана выбранного датасета.
enum FineTuneDatasetTab: String, CaseIterable, Identifiable {
    case overview = "Обзор"
    case examples = "Примеры"
    case baseline = "Baseline"
    case criteria = "Критерии"
    case runs = "Прогоны"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "list.bullet.clipboard"
        case .examples: return "tray.full"
        case .baseline: return "chart.bar.doc.horizontal"
        case .criteria: return "checklist"
        case .runs: return "chart.xyaxis.line"
        }
    }
}

struct FineTuneTabBar: View {
    @Binding var selection: FineTuneDatasetTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FineTuneDatasetTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Кнопка в контент-области (не в тулбаре) не отдаёт System Events ни name, ни
    // description — ни plain, ни bordered, ни через .accessibilityLabel (Ф0 задачи 83:
    // в дампе «AXButton | button»). Единственное, что доходит, — accessibilityValue,
    // поэтому имя вкладки кладётся в него: ax.applescript ищет подпись по
    // name → value → description, смоук находит вкладку по value.
    private func tabButton(_ tab: FineTuneDatasetTab) -> some View {
        let isActive = selection == tab
        return Button {
            selection = tab
        } label: {
            Label(tab.rawValue, systemImage: tab.systemImage)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isActive ? "\(tab.rawValue) — выбрано" : tab.rawValue)
        .help(tab.rawValue)
    }
}
