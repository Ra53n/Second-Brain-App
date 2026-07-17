// PipelineModelsTests.swift — модели пайплайнов (задача 36): Codable
// round-trip, снисходительный декод (миграции + незнакомые значения enum),
// рендер inputTemplate.

import XCTest
@testable import SecondBrain

final class PipelineModelsTests: XCTestCase {

    // MARK: - PipelineConfig

    func testConfigRoundTrip() throws {
        var config = PipelineConfig(name: "Дайджест")
        config.trigger = .cron(expression: "0 9 * * 1-5")
        config.inputTemplate = "Собери дайджест за {{date}}"
        config.projectToolsEnabled = true
        config.enabledMCPServerIDs = [UUID()]
        config.enabledKnowledgeBaseIDs = ["vault"]
        config.agentMode = .single
        config.providerID = ProviderID("openai")
        config.model = "gpt-4o"
        config.destinationChatID = UUID()
        config.catchUpOnStart = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PipelineConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testConfigMigrationFromMinimalJSON() throws {
        // Конфиг из «старой версии»: только имя — обязан загрузиться с дефолтами.
        let json = #"{"name": "Старый"}"#
        let decoded = try JSONDecoder().decode(PipelineConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Старый")
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.trigger, .manual)
        XCTAssertEqual(decoded.agentMode, .fsm)
        XCTAssertFalse(decoded.projectToolsEnabled)
        XCTAssertTrue(decoded.enabledKnowledgeBaseIDs.isEmpty)
        XCTAssertNil(decoded.destinationChatID)
        XCTAssertFalse(decoded.catchUpOnStart)
    }

    func testUnknownAgentModeFallsBackToSingle() throws {
        let json = #"{"name": "x", "agentMode": "квантовый"}"#
        let decoded = try JSONDecoder().decode(PipelineConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.agentMode, .single)
    }

    // MARK: - PipelineTrigger

    func testTriggerRoundTrip() throws {
        let triggers: [PipelineTrigger] = [
            .manual,
            .cron(expression: "*/5 * * * *"),
            .prWatch(owner: "octo", repo: "hello", pollIntervalMin: 10),
        ]
        for trigger in triggers {
            let data = try JSONEncoder().encode(trigger)
            let decoded = try JSONDecoder().decode(PipelineTrigger.self, from: data)
            XCTAssertEqual(decoded, trigger)
        }
    }

    func testUnknownTriggerTypeFallsBackToManual() throws {
        let json = #"{"type": "webhook", "url": "https://example.com"}"#
        let decoded = try JSONDecoder().decode(PipelineTrigger.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .manual)
    }

    func testPRWatchIntervalFloorOnDecode() throws {
        // Слишком частый опрос из старого/ручного конфига поднимается до минимума.
        let json = #"{"type": "prWatch", "owner": "o", "repo": "r", "pollIntervalMin": 1}"#
        let decoded = try JSONDecoder().decode(PipelineTrigger.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .prWatch(owner: "o", repo: "r",
                                         pollIntervalMin: PipelineTrigger.minPollIntervalMin))
    }

    // MARK: - PipelineRun

    func testRunRoundTrip() throws {
        var run = PipelineRun(pipelineID: UUID(), trigger: .cron)
        run.scheduledFor = Date(timeIntervalSince1970: 1_783_000_000)
        run.finishedAt = Date(timeIntervalSince1970: 1_783_000_060)
        run.status = .ok
        run.destinationChatID = UUID()
        run.resultMessageID = UUID()
        run.promptTokens = 100
        run.completionTokens = 20
        run.totalTokens = 120

        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(PipelineRun.self, from: data)
        XCTAssertEqual(decoded, run)
    }

    func testUnknownRunStatusFallsBackToError() throws {
        let json = #"{"pipelineID": "00000000-0000-0000-0000-000000000001", "status": "неведомый"}"#
        let decoded = try JSONDecoder().decode(PipelineRun.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .error, "незнакомый статус честно считается ошибкой")
        XCTAssertEqual(decoded.trigger, .manual)
    }

    // MARK: - PipelineTemplate

    func testRenderSubstitutesPlaceholders() {
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        // 2026-07-20 12:00 UTC = 15:00 МСК — дата одна и та же.
        let date = Date(timeIntervalSince1970: 1_784_548_800)
        let out = PipelineTemplate.render("Дата: {{date}}. Payload: {{trigger_payload}}!",
                                          payload: "PR #7",
                                          date: date, timeZone: moscow)
        XCTAssertEqual(out, "Дата: 2026-07-20. Payload: PR #7!")
    }

    func testRenderMissingPayloadBecomesEmpty() {
        let out = PipelineTemplate.render("[{{trigger_payload}}]", payload: nil)
        XCTAssertEqual(out, "[]")
    }

    func testRenderRepeatedPlaceholders() {
        let out = PipelineTemplate.render("{{trigger_payload}} и {{trigger_payload}}",
                                          payload: "x")
        XCTAssertEqual(out, "x и x")
    }

    func testRenderDateCrossesMidnightByTimeZone() {
        // 23:10 UTC 1 января = 02:10 МСК 2 января: дата зависит от зоны.
        let utc = TimeZone(identifier: "UTC")!
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        let date = Date(timeIntervalSince1970: 1_767_309_000) // 2026-01-01 23:10 UTC
        XCTAssertEqual(PipelineTemplate.render("{{date}}", payload: nil,
                                               date: date, timeZone: utc), "2026-01-01")
        XCTAssertEqual(PipelineTemplate.render("{{date}}", payload: nil,
                                               date: date, timeZone: moscow), "2026-01-02")
    }
}
