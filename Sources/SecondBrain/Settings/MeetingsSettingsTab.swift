// MeetingsSettingsTab.swift — вкладка «Встречи»: раскладка, папка/источник по умолчанию (часть SettingsViews, задача 77).

import SwiftUI

struct MeetingsSettingsTab: View {
    /// Правила раскладки редактируются через MeetingsViewModel — он уже
    /// владеет этим полем (и его же показывает раздел «Встречи»).
    @ObservedObject var meetingsViewModel: MeetingsViewModel

    /// Остальные поля MeetingSettings — локальные черновики; запись через
    /// load-modify-save (MeetingSettingsStore.update), чтобы не стирать чужое.
    @State private var defaultFolder = ""
    /// Папка вне списка vault (вписана руками/удалена) — режим свободного ввода.
    @State private var isCustomFolder = false
    @State private var customFolder = ""
    @State private var defaultSource: RecordingSource = .microphone

    var body: some View {
        Form {
            Section("Правила раскладки для LLM") {
                TextEditor(text: $meetingsViewModel.filingRules)
                    .font(.callout)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if meetingsViewModel.filingRules.isEmpty {
                            Text("Например: «встречи 1:1 клади в Управление командой/1на1». Пусто — заметки идут в папку по умолчанию.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                Button("Сбросить к дефолту") { meetingsViewModel.filingRules = "" }
                    .disabled(meetingsViewModel.filingRules.isEmpty)
            }
            Section("По умолчанию") {
                folderPickerRow
                if isCustomFolder {
                    TextField("Путь папки (например Работа/Встречи)", text: $customFolder)
                        .onChange(of: customFolder) { _, raw in
                            let normalized = MeetingFolderPicker.normalize(raw)
                            defaultFolder = normalized
                            MeetingSettingsStore.update { $0.defaultFolder = normalized }
                        }
                    Text("Несуществующая папка будет создана при первой заметке.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Источник записи", selection: $defaultSource) {
                    ForEach(RecordingSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .onChange(of: defaultSource) { _, source in
                    MeetingSettingsStore.update { $0.defaultSource = source }
                    meetingsViewModel.sourceChoice = source
                }
                Text("Папка используется, когда LLM не предложил валидную; источник — предвыбор при старте записи.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Полные статусы разрешений переехали сюда из раздела «Встречи»
            // (задача 41): в разделе — только предупреждения, когда что-то
            // реально мешает записи.
            Section("Разрешения") {
                PermissionRow(
                    granted: meetingsViewModel.micAuthorized,
                    grantedText: "Микрофон: разрешён",
                    deniedText: "Микрофон: запрещён (Системные настройки → Конфиденциальность)",
                    unknownText: "Микрофон: разрешение запросим при первой записи")
                PermissionRow(
                    granted: MeetingsViewModel.systemAudioSupported ? nil : false,
                    grantedText: "",
                    deniedText: "Системный звук: требуется macOS 14.4+",
                    unknownText: "Системный звук: разрешение запросит macOS при первой записи")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let settings = MeetingSettingsStore.load()
            // Папка вне списка vault откроется в custom-режиме (задача 43).
            let selection = MeetingFolderPicker.settingsSelection(
                stored: settings.defaultFolder,
                available: meetingsViewModel.vaultFolderPaths())
            defaultFolder = selection.path
            isCustomFolder = selection.isCustom
            customFolder = selection.path
            // Не задан — «оба входа» (задача 41), с деградацией на старых macOS.
            defaultSource = settings.resolvedDefaultSource(
                systemAudioSupported: MeetingsViewModel.systemAudioSupported)
        }
    }

    /// Строка «Папка заметок встреч»: меню из штатной, папок vault и «Другая…».
    private var folderPickerRow: some View {
        HStack {
            Text("Папка заметок встреч")
            Spacer()
            Menu {
                Button("Штатная (Meetings/YYYY-MM)") { applyDefaultFolder("") }
                Divider()
                ForEach(MeetingFolderPicker.menuItems(
                    vaultFolders: meetingsViewModel.vaultFolderPaths(),
                    extras: [defaultFolder])) { item in
                    Button {
                        applyDefaultFolder(item.path)
                    } label: {
                        if item.path == defaultFolder && !isCustomFolder {
                            Label(item.path, systemImage: "checkmark")
                        } else {
                            Text(item.path)
                        }
                    }
                }
                Divider()
                Button("Другая…") {
                    customFolder = defaultFolder
                    isCustomFolder = true
                }
            } label: {
                Text(isCustomFolder
                     ? (defaultFolder.isEmpty ? "Другая…" : defaultFolder)
                     : (defaultFolder.isEmpty ? "Штатная (Meetings/YYYY-MM)" : defaultFolder))
            }
            .fixedSize()
        }
    }

    /// Выбор пункта меню: пишем сразу (load-modify-save) и выходим из custom.
    private func applyDefaultFolder(_ path: String) {
        defaultFolder = path
        isCustomFolder = false
        MeetingSettingsStore.update { $0.defaultFolder = path }
    }
}
