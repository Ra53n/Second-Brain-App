// GeneralSettingsTab.swift — вкладка «Общие»: vault + RAG-индекс (часть SettingsViews, задача 77).

import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var vaultManager: VaultManager
    @ObservedObject var ragManager: RagIndexManager

    var body: some View {
        Form {
            Section("Vault") {
                HStack {
                    Text("Текущий")
                    Spacer()
                    Text(vaultManager.vaultURL?.path ?? "не открыт")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Сменить vault…") { vaultManager.openVaultPanel() }
                    if !vaultManager.recentVaults.isEmpty {
                        Menu("Недавние") {
                            ForEach(vaultManager.recentVaults) { recent in
                                Button(recent.name) { vaultManager.openRecent(recent) }
                                    .help(recent.path)
                            }
                        }
                        .fixedSize()
                    }
                }
                Toggle("Показывать скрытые папки (.obsidian, .git…)",
                       isOn: $vaultManager.showsDotItems)
                Toggle("Открывать последний vault при запуске",
                       isOn: $store.settings.restoreLastVault)
            }
            // RAG-индекс vault (задача 13) — переехал из бывшего раздела настроек.
            RagStatusSection(manager: ragManager)
            // Секция «Инструменты проекта» переехала на вкладку «Инструменты»
            // (задача 27) — единая точка настройки туллинга.
        }
        .formStyle(.grouped)
    }
}
