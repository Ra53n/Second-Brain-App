// ConfigTests.swift — тест-смоук каркаса (задача 01).
//
// Проверяем то немногое, что уже есть: идентичность приложения в Config
// (её же использует run.sh — расхождение сломает .app) и контракт
// BackgroundProcessRegistry (идемпотентность terminateAll — его зовёт
// applicationWillTerminate, падать там нельзя).

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

final class BackgroundProcessRegistryTests: XCTestCase {
    /// terminateAll на пустом реестре — no-op; повторный вызов не падает
    /// (идемпотентность нужна applicationWillTerminate).
    func testTerminateAllIsIdempotentOnEmptyRegistry() {
        let registry = BackgroundProcessRegistry.shared
        registry.terminateAll()
        registry.terminateAll()
        XCTAssertEqual(registry.runningCount, 0)
    }

    /// Незапущенный Process регистрируется, но не считается «живым»,
    /// и terminateAll его не трогает (terminate() по не-running процессу падает).
    func testRegisterNotRunningProcess() {
        let registry = BackgroundProcessRegistry.shared
        registry.register(Process())
        XCTAssertEqual(registry.runningCount, 0)
        registry.terminateAll()
        XCTAssertEqual(registry.runningCount, 0)
    }
}
