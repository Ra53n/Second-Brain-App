// ConfigTests.swift — тест-смоук каркаса (задача 01).
//
// Идентичность приложения в Config: её использует run.sh — расхождение
// сломает .app. Тесты BackgroundProcessRegistry переехали в
// LocalRuntimeTests.swift (задача 09 дала реестру полную реализацию).

import XCTest
@testable import SecondBrain

final class ConfigTests: XCTestCase {
    /// Bundle id из Config обязан совпадать с тем, что run.sh пишет в Info.plist.
    func testBundleIDMatchesRunScript() {
        XCTAssertEqual(Config.bundleID, "com.local.second-brain")
    }

    func testAppNameIsNotEmpty() {
        XCTAssertEqual(Config.appName, "Second Brain")
    }

    /// Папка производных данных — внутри Application Support и названа по приложению.
    func testAppSupportDirectory() {
        let path = Config.appSupportDirectory.path
        XCTAssertTrue(path.contains("Application Support"))
        XCTAssertTrue(path.hasSuffix("SecondBrain"))
    }
}

