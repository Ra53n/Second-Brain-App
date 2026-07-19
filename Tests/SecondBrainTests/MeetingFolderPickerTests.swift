// MeetingFolderPickerTests.swift — тесты задачи 43: модель меню выбора папки
// для заметки встречи (нормализация, пункты, предвыбор, строка «ИИ предлагает»,
// состояние пикера настроек, подпись чипа) + извлечённый список папок vault.

import XCTest
@testable import SecondBrain

final class MeetingFolderPickerTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeTrimsWhitespaceAndSlashes() {
        XCTAssertEqual(MeetingFolderPicker.normalize("  /Работа/Встречи/  "), "Работа/Встречи")
        XCTAssertEqual(MeetingFolderPicker.normalize("///"), "")
        XCTAssertEqual(MeetingFolderPicker.normalize("   "), "")
        XCTAssertEqual(MeetingFolderPicker.normalize("Работа"), "Работа")
    }

    // MARK: - menuItems

    func testMenuItemsKeepVaultOrderAndComputeDepth() {
        let items = MeetingFolderPicker.menuItems(
            vaultFolders: ["Работа", "Работа/Релизы", "Личное"], extras: [])
        XCTAssertEqual(items.map(\.path), ["Работа", "Работа/Релизы", "Личное"])
        XCTAssertEqual(items.map(\.depth), [0, 1, 0])
    }

    func testMenuItemsAppendUnknownExtrasAtEnd() {
        let items = MeetingFolderPicker.menuItems(
            vaultFolders: ["Работа"],
            extras: ["Meetings/2026-07", "Работа", ""])
        XCTAssertEqual(items.map(\.path), ["Работа", "Meetings/2026-07"])
    }

    func testMenuItemsDeduplicateAfterNormalization() {
        let items = MeetingFolderPicker.menuItems(
            vaultFolders: ["Работа", "Работа/"],
            extras: ["/Работа/"])
        XCTAssertEqual(items.map(\.path), ["Работа"])
    }

    // MARK: - preselected

    private let july = DateComponents(calendar: .current, year: 2026, month: 7, day: 19).date!

    func testPreselectedPriorityChain() {
        // Подтверждённая ранее — поверх всего.
        XCTAssertEqual(MeetingFolderPicker.preselected(
            confirmed: "Личное", defaultFolder: "Работа", suggested: "Работа/Релизы", date: july),
            "Личное")
        // Затем дефолт настроек.
        XCTAssertEqual(MeetingFolderPicker.preselected(
            confirmed: nil, defaultFolder: "Работа", suggested: "Работа/Релизы", date: july),
            "Работа")
        // Затем предложение ИИ.
        XCTAssertEqual(MeetingFolderPicker.preselected(
            confirmed: nil, defaultFolder: "  ", suggested: "Работа/Релизы", date: july),
            "Работа/Релизы")
        // И только потом штатная папка месяца.
        XCTAssertEqual(MeetingFolderPicker.preselected(
            confirmed: nil, defaultFolder: "", suggested: "", date: july),
            MeetingNoteWriter.defaultFolder(for: july))
    }

    func testPreselectedNormalizesWinner() {
        XCTAssertEqual(MeetingFolderPicker.preselected(
            confirmed: nil, defaultFolder: " /Работа/ ", suggested: "", date: july),
            "Работа")
    }

    // MARK: - aiSuggestion

    func testAiSuggestionHiddenWhenEmptyOrSelected() {
        XCTAssertNil(MeetingFolderPicker.aiSuggestion(suggested: "", currentSelection: "Работа"))
        XCTAssertNil(MeetingFolderPicker.aiSuggestion(suggested: "Работа", currentSelection: "Работа/"))
    }

    func testAiSuggestionShownWhenDiffers() {
        XCTAssertEqual(MeetingFolderPicker.aiSuggestion(
            suggested: "Работа/Релизы", currentSelection: "Работа"), "Работа/Релизы")
    }

    // MARK: - settingsSelection

    func testSettingsSelectionStates() {
        // Пусто — штатная.
        var s = MeetingFolderPicker.settingsSelection(stored: "", available: ["Работа"])
        XCTAssertEqual(s.path, ""); XCTAssertFalse(s.isCustom)
        // Значение из списка — обычный пункт.
        s = MeetingFolderPicker.settingsSelection(stored: "Работа", available: ["Работа"])
        XCTAssertEqual(s.path, "Работа"); XCTAssertFalse(s.isCustom)
        // Вне списка — custom-режим.
        s = MeetingFolderPicker.settingsSelection(stored: "Архив/2020", available: ["Работа"])
        XCTAssertEqual(s.path, "Архив/2020"); XCTAssertTrue(s.isCustom)
    }

    // MARK: - chipTitle

    func testChipTitleShowsDefaultOrMonthlyFolder() {
        XCTAssertEqual(MeetingFolderPicker.chipTitle(defaultFolder: "Работа/Встречи", date: july),
                       "Папка: Работа/Встречи")
        XCTAssertEqual(MeetingFolderPicker.chipTitle(defaultFolder: "  ", date: july),
                       "Папка: \(MeetingNoteWriter.defaultFolder(for: july))")
    }
}

// MARK: - Список папок vault (извлечён из замыкания пайплайна, задача 43)

@MainActor
final class RelativeFolderPathsTests: XCTestCase {

    private var vaultDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-paths-tests-\(UUID().uuidString)")
        for sub in ["Работа/Релизы", "Личное", ".obsidian"] {
            try FileManager.default.createDirectory(
                at: vaultDir.appendingPathComponent(sub),
                withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    func testRelativePathsSkipRootAndDotFolders() throws {
        let root = try VaultTree.build(at: vaultDir, showsDotItems: false)
        let paths = MeetingsViewModel.relativeFolderPaths(root: root, vaultURL: vaultDir)
        // Pre-order: родитель раньше детей; корень и dot-папки исключены.
        XCTAssertEqual(paths, ["Личное", "Работа", "Работа/Релизы"])
    }
}
