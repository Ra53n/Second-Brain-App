// DeepLinkTests.swift — тесты навигации по URL-схеме secondbrain:// (задача 50).
//
// Что покрыто: все валидные маршруты разделов и вкладок настроек, регистр,
// мусор и чужие схемы (обязаны давать nil — приложение молчит), пустой путь,
// лишние компоненты пути, круговорот slug ↔ AppSection.

import XCTest
@testable import SecondBrain

final class DeepLinkTests: XCTestCase {

    private func parse(_ string: String) -> DeepLink? {
        guard let url = URL(string: string) else { return nil }
        return DeepLinkParser.parse(url)
    }

    func testВсеРазделыОткрываютсяПоСлагу() {
        let expected: [(String, AppSection)] = [
            ("notes", .notes), ("meetings", .meetings), ("chat", .chat),
            ("pipelines", .pipelines), ("finetune", .finetune), ("settings", .settings)
        ]
        for (slug, section) in expected {
            XCTAssertEqual(parse("secondbrain://section/\(slug)"), .section(section), slug)
        }
    }

    func testВсеВкладкиНастроекОткрываются() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(parse("secondbrain://settings/\(tab.rawValue)"),
                           .settings(tab), tab.rawValue)
        }
    }

    /// Ссылку пишет человек — регистр не должен иметь значения.
    func testРегистрНеВажен() {
        XCTAssertEqual(parse("SECONDBRAIN://SECTION/MEETINGS"), .section(.meetings))
        XCTAssertEqual(parse("secondbrain://settings/LOCALMODELS"), .settings(.localModels))
    }

    /// Мусор обязан давать nil: приложение молча игнорирует, а не падает
    /// и не показывает ошибку на каждый чужой URL.
    func testМусорДаётNil() {
        let garbage = [
            "secondbrain://section/unknown",     // нет такого раздела
            "secondbrain://settings/unknown",    // нет такой вкладки
            "secondbrain://unknownhost/notes",   // неизвестный хост
            "secondbrain://section",             // хост без значения
            "secondbrain://section/",            // пустое значение
            "secondbrain://",                    // пустая ссылка
            "https://example.com/section/notes", // чужая схема
            "file:///tmp/notes"                  // чужая схема
        ]
        for string in garbage {
            XCTAssertNil(parse(string), string)
        }
    }

    /// Лишние компоненты пути не мешают: значение берётся из первого.
    func testЛишниеКомпонентыПутиИгнорируются() {
        XCTAssertEqual(parse("secondbrain://section/chat/extra/tail"), .section(.chat))
    }

    func testSlugИРазделВзаимнообратимы() {
        for section in AppSection.allCases {
            XCTAssertEqual(AppSection(slug: section.slug), section, section.slug)
        }
        XCTAssertNil(AppSection(slug: "нетакого"))
        XCTAssertNil(AppSection(slug: ""))
    }

    /// Русский rawValue — подпись в UI, в контракт ссылок он попасть не должен.
    func testРусскийRawValueНеРаботаетКакСлаг() {
        XCTAssertNil(AppSection(slug: "Заметки"))
        XCTAssertNil(parse("secondbrain://section/Заметки"))
    }
}
