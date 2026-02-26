import Foundation
import Darwin
import AppKit
import SwiftUI
import XCTest

@testable import TokenMeter

final class TokenMeterTests: XCTestCase {
    func testCodexSettingsDefaultTrack1SourceIsMethodB() {
        let settings = CodexSettings()
        XCTAssertEqual(settings.track1Source, .methodB)
    }

    func testLocalizationFallbackMissingKeyReturnsKey() {
        let bundle = Bundle(for: AppRuntime.self)
        let key = "test.missing_key"
        XCTAssertEqual(NSLocalizedString(key, bundle: bundle, value: key, comment: ""), key)
    }

    @MainActor
    func testRuntimeLocaleSwitchRerendersLocalizedText() {
        let controller = AppLocaleController(initialSetting: .fixed("en"), loadFromStore: false)
        let appBundle = Bundle(for: AppRuntime.self)

        let key = "app.title"
        let expectedEn = localizedString(key, bundle: appBundle, languageCode: "en")
        let expectedKo = localizedString(key, bundle: appBundle, languageCode: "ko")
        XCTAssertNotEqual(expectedEn, expectedKo)

        let hosting = NSHostingView(
            rootView: LocaleSwitchingHarness(controller: controller, bundle: appBundle)
                .frame(width: 300, height: 60)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 60)

        XCTAssertEqual(waitForText(expectedEn, in: hosting, timeoutSec: 1.0), expectedEn)

        controller.setSetting(.fixed("ko"))
        XCTAssertEqual(waitForText(expectedKo, in: hosting, timeoutSec: 1.0), expectedKo)
    }

    func testCodexTrack1SourceRejectsMethodC() {
        let json = """
        {
          "claude": {
            "allowMethodC": true,
            "cliPathOverride": null,
            "enabled": true,
            "track1Source": "method_b"
          },
          "codex": {
            "cliPathOverride": null,
            "enabled": true,
            "track1Source": "method_c"
          },
          "locale": {
            "mode": "system"
          },
          "refreshIntervalSec": 60
        }
        """

        let data = Data(json.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: data)) { error in
            guard (error as? DecodingError) != nil else {
                XCTFail("Expected DecodingError, got: \(String(describing: error))")
                return
            }
        }
    }

    func testAppSettingsDecodeWithoutWidgetTrack2ScaleDefaultsTo24h() throws {
        let json = """
        {
          "claude": {
            "allowMethodC": false,
            "cliPathOverride": null,
            "enabled": true,
            "track1Source": "method_b"
          },
          "codex": {
            "cliPathOverride": null,
            "enabled": true,
            "track1Source": "method_b"
          },
          "locale": {
            "mode": "system"
          },
          "refreshIntervalSec": 60
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.widgetTrack2TimeScale, .hours24)
    }

    func testCodexMethodBAdapterValidPayloadMapsSnapshot() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let resetAt = Date(timeIntervalSince1970: 1_700_000_000)

        let json = """
        {
          "plan": "pro",
          "windows": [
            {
              "windowId": "weekly",
              "scope": "codex",
              "usedPercent": 25.0,
              "remainingPercent": 75.0,
              "resetAt": 1700000000
            }
          ]
        }
        """

        let snapshot = try CodexTrack1MethodBAdapter.snapshot(from: Data(json.utf8), observedAt: observedAt)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.parserVersion, CodexTrack1MethodBAdapter.parserVersion)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25.0)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 75.0)
        XCTAssertEqual(snapshot.windows[0].resetAt, resetAt)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "codex")
    }

    func testCodexMethodBAdapterMissingResetDegradesGracefully() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)

        let json = """
        {
          "plan": "pro",
          "windows": [
            {
              "windowId": "weekly",
              "scope": "codex",
              "usedPercent": 25.0,
              "remainingPercent": 75.0
            }
          ]
        }
        """

        let snapshot = try CodexTrack1MethodBAdapter.snapshot(from: Data(json.utf8), observedAt: observedAt)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertNil(snapshot.windows[0].resetAt)
        XCTAssertEqual(snapshot.confidence, .medium)
    }

    func testCodexMethodBAdapterHandlesSchemaDriftFixture() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let resetAt = Date(timeIntervalSince1970: 1_767_225_600)

        let data = try fixtureData("track1_codex_methodb_drift.json")
        let snapshot = try CodexTrack1MethodBAdapter.snapshot(from: data, observedAt: observedAt)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.parserVersion, CodexTrack1MethodBAdapter.parserVersion)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .rolling5h)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 10.5)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 89.5)
        XCTAssertEqual(snapshot.windows[0].resetAt, resetAt)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "codex")
    }

    func testCodexMethodBAdapterMalformedRequiredFieldsThrows() {
        let missingWindows = """
        {
          "plan": "pro"
        }
        """

        XCTAssertThrowsError(try CodexTrack1MethodBAdapter.snapshot(from: Data(missingWindows.utf8))) { error in
            XCTAssertEqual(error as? CodexTrack1MethodBAdapterError, .missingWindows)
        }

        let invalidWindow = """
        {
          "plan": "pro",
          "windows": [
            {
              "windowId": "weekly",
              "usedPercent": 10.0
            }
          ]
        }
        """

        XCTAssertThrowsError(try CodexTrack1MethodBAdapter.snapshot(from: Data(invalidWindow.utf8))) { error in
            XCTAssertEqual(error as? CodexTrack1MethodBAdapterError, .invalidWindow(index: 0))
        }
    }

    func testCodexTrack2PrimaryParserParsesNormalJSONLFixture() throws {
        let jsonl = try fixtureText("track2_codex_primary_normal.jsonl")

        let points = CodexTrack2PrimaryParser.timelinePoints(fromJSONL: jsonl, sourceFile: "sessions/2026-01-02/main.jsonl")

        XCTAssertEqual(points.count, 2)

        XCTAssertEqual(points[0].provider, .codex)
        XCTAssertEqual(points[0].timestamp, Date(timeIntervalSince1970: 1_767_323_045))
        XCTAssertEqual(points[0].sessionId, "sess_1")
        XCTAssertEqual(points[0].model, "gpt-5")
        XCTAssertEqual(points[0].promptTokens, 12)
        XCTAssertEqual(points[0].completionTokens, 8)
        XCTAssertEqual(points[0].totalTokens, 20)
        XCTAssertEqual(points[0].sourceFile, "sessions/2026-01-02/main.jsonl")
        XCTAssertEqual(points[0].confidence, .medium)
        XCTAssertEqual(points[0].parserVersion, CodexTrack2PrimaryParser.parserVersion)

        XCTAssertEqual(points[1].provider, .codex)
        XCTAssertEqual(points[1].timestamp, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(points[1].sessionId, "sess_1")
        XCTAssertEqual(points[1].model, "gpt-5")
        XCTAssertEqual(points[1].promptTokens, 5)
        XCTAssertEqual(points[1].completionTokens, 7)
        XCTAssertEqual(points[1].totalTokens, 12)
        XCTAssertEqual(points[1].sourceFile, "sessions/2026-01-02/main.jsonl")
        XCTAssertEqual(points[1].confidence, .medium)
        XCTAssertEqual(points[1].parserVersion, CodexTrack2PrimaryParser.parserVersion)
    }

    func testCodexTrack2PrimaryParserHandlesSchemaDriftWithDegradedConfidence() throws {
        let jsonl = try fixtureText("track2_codex_primary_drift.jsonl")

        let points = CodexTrack2PrimaryParser.timelinePoints(fromJSONL: jsonl, sourceFile: "sessions/drift.jsonl")

        XCTAssertEqual(points.count, 2)

        XCTAssertEqual(points[0].timestamp, Date(timeIntervalSince1970: 1_767_323_105))
        XCTAssertEqual(points[0].sessionId, nil)
        XCTAssertEqual(points[0].model, "gpt-4.1")
        XCTAssertEqual(points[0].promptTokens, 9)
        XCTAssertNil(points[0].completionTokens)
        XCTAssertNil(points[0].totalTokens)
        XCTAssertEqual(points[0].confidence, .low)
        XCTAssertEqual(points[0].parserVersion, CodexTrack2PrimaryParser.parserVersion)

        XCTAssertEqual(points[1].timestamp, Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertEqual(points[1].sessionId, "sess_2")
        XCTAssertEqual(points[1].model, "gpt-4.1")
        XCTAssertNil(points[1].promptTokens)
        XCTAssertNil(points[1].completionTokens)
        XCTAssertEqual(points[1].totalTokens, 101)
        XCTAssertEqual(points[1].confidence, .low)
        XCTAssertEqual(points[1].parserVersion, CodexTrack2PrimaryParser.parserVersion)
    }

    func testCodexTrack2PrimaryParserBackfillsModelForSplitTokenEventsUsingNearbyContext() {
        let jsonl = """
        {"timestamp":"2026-01-02T03:01:00Z","session_id":"sess_split","turn_context":{"model":"gpt-5.3-codex"}}
        {"timestamp":"2026-01-02T03:01:05Z","session_id":"sess_split","event_msg":"assistant","token_count":42}
        {"timestamp":"2026-01-02T03:02:00Z","turn_context":{"model":"gpt-5.3-codex"}}
        {"timestamp":"2026-01-02T03:02:03Z","event_msg":"assistant","token_count":9}
        """

        let points = CodexTrack2PrimaryParser.timelinePoints(fromJSONL: jsonl, sourceFile: "sessions/split-events.jsonl")

        XCTAssertEqual(points.count, 2)

        XCTAssertEqual(points[0].sessionId, "sess_split")
        XCTAssertEqual(points[0].model, "gpt-5.3-codex")
        XCTAssertEqual(points[0].totalTokens, 42)
        XCTAssertEqual(points[0].confidence, .low)

        XCTAssertNil(points[1].sessionId)
        XCTAssertEqual(points[1].model, "gpt-5.3-codex")
        XCTAssertEqual(points[1].totalTokens, 9)
        XCTAssertEqual(points[1].confidence, .low)
    }

    func testCodexTrack2PrimaryParserBackfillsModelWithinSameSession() {
        let jsonl = """
        {"timestamp":"2026-01-02T03:04:05Z","session_id":"sess_backfill","model":"gpt-5.2-codex","usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}
        {"timestamp":"2026-01-02T03:05:05Z","session_id":"sess_backfill","usage":{"total_tokens":9}}
        """

        let points = CodexTrack2PrimaryParser.timelinePoints(fromJSONL: jsonl, sourceFile: "sessions/backfill.jsonl")

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].model, "gpt-5.2-codex")
        XCTAssertEqual(points[1].model, "gpt-5.2-codex")
        XCTAssertEqual(points[1].totalTokens, 9)
    }

    func testCodexTrack2PrimaryParserSkipsCorruptLineAndContinues() {
        let jsonl = """
        {"timestamp":"2026-01-02T03:04:05Z","session_id":"sess_a","model":"gpt-5","usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}
        {"timestamp":"bad"
        {"timestamp":"2026-01-02T03:06:05Z","session_id":"sess_b","model":"gpt-5","usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}
        """

        let points = CodexTrack2PrimaryParser.timelinePoints(from: Data(jsonl.utf8), sourceFile: "sessions/corrupt.jsonl")

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].sessionId, "sess_a")
        XCTAssertEqual(points[0].totalTokens, 5)
        XCTAssertEqual(points[1].sessionId, "sess_b")
        XCTAssertEqual(points[1].totalTokens, 3)
        XCTAssertEqual(points[0].confidence, .medium)
        XCTAssertEqual(points[1].confidence, .medium)
        XCTAssertEqual(points[0].parserVersion, CodexTrack2PrimaryParser.parserVersion)
        XCTAssertEqual(points[1].parserVersion, CodexTrack2PrimaryParser.parserVersion)
    }

    func testClaudeTrack2SecondaryParserSkipsCorruptJSONLLineAndContinues() {
        let jsonl = """
        {"timestamp":"2026-01-04T01:10:03Z","session_id":"proj_a","model":"claude-3-5-sonnet","usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}
        {"timestamp":"bad"
        {"time":1700001300,"conversation_id":"proj_b","model_name":"claude-3-7-sonnet","token_usage":{"input_tokens":5,"output_tokens":4}}
        """

        let points = ClaudeTrack2SecondaryParser.timelinePoints(from: Data(jsonl.utf8), sourceFile: "projects/alpha/activity.jsonl")

        XCTAssertEqual(points.count, 2)

        XCTAssertEqual(points[0].provider, .claude)
        XCTAssertEqual(points[0].timestamp, Date(timeIntervalSince1970: 1_767_489_003))
        XCTAssertEqual(points[0].sessionId, "proj_a")
        XCTAssertEqual(points[0].model, "claude-3-5-sonnet")
        XCTAssertEqual(points[0].promptTokens, 4)
        XCTAssertEqual(points[0].completionTokens, 2)
        XCTAssertEqual(points[0].totalTokens, 6)
        XCTAssertEqual(points[0].sourceFile, "secondary_local:projects/alpha/activity.jsonl")
        XCTAssertEqual(points[0].confidence, .medium)
        XCTAssertEqual(points[0].parserVersion, ClaudeTrack2SecondaryParser.parserVersion)

        XCTAssertEqual(points[1].provider, .claude)
        XCTAssertEqual(points[1].timestamp, Date(timeIntervalSince1970: 1_700_001_300))
        XCTAssertEqual(points[1].sessionId, "proj_b")
        XCTAssertEqual(points[1].model, "claude-3-7-sonnet")
        XCTAssertEqual(points[1].promptTokens, 5)
        XCTAssertEqual(points[1].completionTokens, 4)
        XCTAssertEqual(points[1].totalTokens, 9)
        XCTAssertEqual(points[1].sourceFile, "secondary_local:projects/alpha/activity.jsonl")
        XCTAssertEqual(points[1].confidence, .medium)
        XCTAssertEqual(points[1].parserVersion, ClaudeTrack2SecondaryParser.parserVersion)
    }

    func testClaudeTrack2SecondaryParserHandlesSchemaDriftFixture() throws {
        let jsonl = try fixtureText("track2_claude_secondary_drift.jsonl")
        let points = ClaudeTrack2SecondaryParser.timelinePoints(from: Data(jsonl.utf8), sourceFile: "projects/drift/activity.jsonl")

        XCTAssertEqual(points.count, 2)

        XCTAssertEqual(points[0].provider, .claude)
        XCTAssertEqual(points[0].timestamp, Date(timeIntervalSince1970: 1_767_571_201))
        XCTAssertEqual(points[0].sessionId, "thr_1")
        XCTAssertEqual(points[0].model, "claude-3-5-sonnet")
        XCTAssertNil(points[0].promptTokens)
        XCTAssertNil(points[0].completionTokens)
        XCTAssertEqual(points[0].totalTokens, 17)
        XCTAssertEqual(points[0].sourceFile, "secondary_local:projects/drift/activity.jsonl")
        XCTAssertEqual(points[0].confidence, .low)
        XCTAssertEqual(points[0].parserVersion, ClaudeTrack2SecondaryParser.parserVersion)

        XCTAssertEqual(points[1].provider, .claude)
        XCTAssertEqual(points[1].timestamp, Date(timeIntervalSince1970: 1_700_001_500))
        XCTAssertEqual(points[1].sessionId, "thr_2")
        XCTAssertEqual(points[1].model, "claude-3-7-sonnet")
        XCTAssertEqual(points[1].promptTokens, 3)
        XCTAssertNil(points[1].completionTokens)
        XCTAssertNil(points[1].totalTokens)
        XCTAssertEqual(points[1].sourceFile, "secondary_local:projects/drift/activity.jsonl")
        XCTAssertEqual(points[1].confidence, .low)
        XCTAssertEqual(points[1].parserVersion, ClaudeTrack2SecondaryParser.parserVersion)
    }

    func testClaudeMethodBAdapterValidPayloadMapsSnapshot() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let resetAt = Date(timeIntervalSince1970: 1_700_000_000)

        let json = """
        {
          "plan": "pro",
          "windows": [
            {
              "windowId": "weekly",
              "scope": "claude",
              "usedPercent": 25.0,
              "remainingPercent": 75.0,
              "resetAt": 1700000000
            }
          ]
        }
        """

        let snapshot = try ClaudeTrack1MethodBAdapter.snapshot(from: Data(json.utf8), observedAt: observedAt)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.parserVersion, ClaudeTrack1MethodBAdapter.parserVersion)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25.0)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 75.0)
        XCTAssertEqual(snapshot.windows[0].resetAt, resetAt)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude")
    }

    func testClaudeMethodBAdapterMissingResetDegradesGracefully() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)

        let json = """
        {
          "plan": "pro",
          "windows": [
            {
              "windowId": "weekly",
              "scope": "claude",
              "usedPercent": 25.0,
              "remainingPercent": 75.0
            }
          ]
        }
        """

        let snapshot = try ClaudeTrack1MethodBAdapter.snapshot(from: Data(json.utf8), observedAt: observedAt)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertNil(snapshot.windows[0].resetAt)
        XCTAssertEqual(snapshot.confidence, .medium)
    }

    func testClaudeMethodBAdapterHandlesSchemaDriftFixture() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let resetAt = Date(timeIntervalSince1970: 1_767_225_600)

        let data = try fixtureData("track1_claude_methodb_drift.json")
        let snapshot = try ClaudeTrack1MethodBAdapter.snapshot(from: data, observedAt: observedAt)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .plus)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.parserVersion, ClaudeTrack1MethodBAdapter.parserVersion)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 1.0)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 99.0)
        XCTAssertEqual(snapshot.windows[0].resetAt, resetAt)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude")
    }

    func testClaudeMethodBAdapterUnavailableOrMalformedThrows() {
        let missingWindows = """
        {
          "plan": "pro"
        }
        """

        XCTAssertThrowsError(try ClaudeTrack1MethodBAdapter.snapshot(from: Data(missingWindows.utf8))) { error in
            XCTAssertEqual(error as? ClaudeTrack1MethodBAdapterError, .missingWindows)
        }

        let invalidWindow = """
        {
          "plan": "pro",
          "windows": [
            {
              "windowId": "weekly",
              "usedPercent": 10.0
            }
          ]
        }
        """

        XCTAssertThrowsError(try ClaudeTrack1MethodBAdapter.snapshot(from: Data(invalidWindow.utf8))) { error in
            XCTAssertEqual(error as? ClaudeTrack1MethodBAdapterError, .invalidWindow(index: 0))
        }
    }

    func testClaudeTrack1SourceRejectsMethodCWhenNotAllowed() async throws {
        let json = """
        {
          "claude": {
            "allowMethodC": false,
            "cliPathOverride": null,
            "enabled": true,
            "track1Source": "method_c"
          },
          "codex": {
            "cliPathOverride": null,
            "enabled": true,
            "track1Source": "method_b"
          },
          "locale": {
            "mode": "system"
          },
          "refreshIntervalSec": 60
        }
        """

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url, options: [.atomic])

        let store = SettingsStore(settingsURLOverride: url)
        do {
            _ = try await store.load()
            XCTFail("Expected SettingsError.invalidClaudeTrack1Source")
        } catch {
            XCTAssertEqual(error as? SettingsError, .invalidClaudeTrack1Source)
        }
    }

    func testClaudeMethodCDefaultOffAndNotSelectedByDefault() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)

        let settings = ClaudeSettings()
        XCTAssertEqual(settings.track1Source, .methodB)
        XCTAssertEqual(settings.allowMethodC, false)

        let methodBJSON = """
        {
          "plan": "pro",
          "windows": [
            {
              "windowId": "weekly",
              "scope": "claude",
              "usedPercent": 25.0,
              "remainingPercent": 75.0,
              "resetAt": 1700000000
            }
          ]
        }
        """

        let snapshot = try ClaudeTrack1Adapter.snapshot(from: Data(methodBJSON.utf8), settings: settings, observedAt: observedAt)
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.source, .cliMethodB)
    }

    func testClaudeMethodCExplicitEnableAndSelectUsesMethodC() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let resetAt = Date(timeIntervalSince1970: 1_700_000_000)

        let settings = ClaudeSettings(track1Source: .methodC, allowMethodC: true)
        let methodCJSON = """
        {
          "planLabel": "pro",
          "usage": {
            "items": [
              {
                "id": "weekly",
                "scope_label": "claude",
                "used": 25.0,
                "remaining": 75.0,
                "resets_at": 1700000000
              }
            ]
          }
        }
        """

        let snapshot = try ClaudeTrack1Adapter.snapshot(from: Data(methodCJSON.utf8), settings: settings, observedAt: observedAt)
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.source, .webMethodC)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.parserVersion, ClaudeTrack1MethodCAdapter.parserVersion)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25.0)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 75.0)
        XCTAssertEqual(snapshot.windows[0].resetAt, resetAt)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude")
    }

    func testClaudeMethodCAdapterHandlesSchemaDriftFixture() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let resetAt = Date(timeIntervalSince1970: 1_767_225_600)

        let settings = ClaudeSettings(track1Source: .methodC, allowMethodC: true)
        let data = try fixtureData("track1_claude_methodc_drift.json")
        let snapshot = try ClaudeTrack1Adapter.snapshot(from: data, settings: settings, observedAt: observedAt)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.observedAt, observedAt)
        XCTAssertEqual(snapshot.source, .webMethodC)
        XCTAssertEqual(snapshot.plan, .team)
        XCTAssertEqual(snapshot.confidence, .high)
        XCTAssertEqual(snapshot.parserVersion, ClaudeTrack1MethodCAdapter.parserVersion)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 33.3)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 66.7)
        XCTAssertEqual(snapshot.windows[0].resetAt, resetAt)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude")
    }

    func testClaudeMethodCAdapterMalformedPayloadThrows() {
        let missingWindows = """
        {
          "plan": "pro"
        }
        """

        XCTAssertThrowsError(try ClaudeTrack1MethodCAdapter.snapshot(from: Data(missingWindows.utf8))) { error in
            XCTAssertEqual(error as? ClaudeTrack1MethodCAdapterError, .missingWindows)
        }
    }

    func testCLIToolDiscoveryFindsExecutableInSearchPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let exe = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: exe, options: [.atomic])
        let rc = exe.path.withCString { chmod($0, 0o755) }
        XCTAssertEqual(rc, 0)

        XCTAssertEqual(
            CLIToolDiscovery.findExecutable(named: "claude", searchPaths: [dir]),
            exe
        )
    }

    func testCLIToolProbeOverrideInvalidPathUnhealthyWithReason() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let override = dir.appendingPathComponent("missing").path

        let health = CLIToolDiscovery.probeHealth(
            toolName: "claude",
            overridePath: override,
            environment: ["PATH": ""],
            fallbackDirectories: []
        )

        XCTAssertEqual(health.state, .invalid)
        XCTAssertEqual(health.discovery.source, .manualOverride)
        XCTAssertEqual(health.discovery.reasonCode, .overrideNotFound)
    }

    func testCLIToolProbeFindsInPATHAndParsesVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let exe = dir.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "claude 1.2.3"
          exit 0
        fi
        exit 2
        """
        try Data(script.utf8).write(to: exe, options: [.atomic])
        let rc = exe.path.withCString { chmod($0, 0o755) }
        XCTAssertEqual(rc, 0)

        let health = CLIToolDiscovery.probeHealth(
            toolName: "claude",
            overridePath: nil,
            environment: ["PATH": dir.path],
            fallbackDirectories: [],
            versionTimeoutSec: 2.0
        )

        XCTAssertEqual(health.state, .found)
        XCTAssertEqual(health.discovery.source, .path)
        XCTAssertEqual(health.discovery.executablePath, exe.path)
        XCTAssertEqual(health.version.state, .found)
        XCTAssertEqual(health.version.version, "1.2.3")
    }

    func testCLIToolProbeFallbackDirectoryWhenPATHMisses() throws {
        let pathDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fallbackDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)

        let exe = fallbackDir.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        echo "claude 9.9.9"
        exit 0
        """
        try Data(script.utf8).write(to: exe, options: [.atomic])
        let rc = exe.path.withCString { chmod($0, 0o755) }
        XCTAssertEqual(rc, 0)

        let health = CLIToolDiscovery.probeHealth(
            toolName: "claude",
            overridePath: nil,
            environment: ["PATH": pathDir.path],
            fallbackDirectories: [fallbackDir]
        )

        XCTAssertEqual(health.state, .found)
        XCTAssertEqual(health.discovery.source, .fallbackDirectory)
        XCTAssertEqual(health.discovery.executablePath, exe.path)
    }

    func testCLIToolProbeAsyncOverrideInvalidPathUnhealthyWithReason() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let override = dir.appendingPathComponent("missing").path

        let health = await CLIToolDiscovery.probeHealthAsync(
            toolName: "claude",
            overridePath: override,
            environment: ["PATH": ""],
            fallbackDirectories: []
        )

        XCTAssertEqual(health.state, .invalid)
        XCTAssertEqual(health.discovery.source, .manualOverride)
        XCTAssertEqual(health.discovery.reasonCode, .overrideNotFound)
    }

    func testCLIToolProbeAsyncFindsInPATHAndParsesVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let exe = dir.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "claude 1.2.3"
          exit 0
        fi
        exit 2
        """
        try Data(script.utf8).write(to: exe, options: [.atomic])
        let rc = exe.path.withCString { chmod($0, 0o755) }
        XCTAssertEqual(rc, 0)

        let health = await CLIToolDiscovery.probeHealthAsync(
            toolName: "claude",
            overridePath: nil,
            environment: ["PATH": dir.path],
            fallbackDirectories: [],
            versionTimeoutSec: 2.0
        )

        XCTAssertEqual(health.state, .found)
        XCTAssertEqual(health.discovery.source, .path)
        XCTAssertEqual(health.discovery.executablePath, exe.path)
        XCTAssertEqual(health.version.state, .found)
        XCTAssertEqual(health.version.version, "1.2.3")
    }

    func testTrack1StoreInsertReadIsolation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let track1URL = dir.appendingPathComponent("track1.json")
        let track2URL = dir.appendingPathComponent("track2.json")

        let track1Store = Track1Store(snapshotsURLOverride: track1URL)
        let snapshot = Track1Snapshot(
            provider: .codex,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .cliMethodB,
            plan: .unknown,
            windows: [
                Track1Window(
                    windowId: .weekly,
                    usedPercent: nil,
                    remainingPercent: nil,
                    resetAt: nil,
                    rawScopeLabel: "codex"
                )
            ],
            confidence: .high,
            parserVersion: "t1_fixture_v1"
        )

        try await track1Store.append(snapshot)
        let track1Loaded = try await track1Store.loadAll()
        XCTAssertEqual(track1Loaded, [snapshot])

        let track2Store = Track2Store(pointsURLOverride: track2URL)
        let track2Loaded = try await track2Store.loadAll()
        XCTAssertEqual(track2Loaded, [])
    }

    func testRealCollectionPipelineCodexTrack1AndTrack2PopulateStores() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDir = dir.appendingPathComponent("home", isDirectory: true)
        let binDir = dir.appendingPathComponent("bin", isDirectory: true)
        let sessionsDir = homeDir.appendingPathComponent(".codex/sessions/2026-02-24", isDirectory: true)

        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let codexScript = binDir.appendingPathComponent("codex")
        let codexScriptBody = """
        #!/bin/sh
        if [ "$1" = "usage" ] && [ "$2" = "--json" ]; then
          cat <<'JSON'
        {"plan":"pro","windows":[{"windowId":"weekly","scope":"codex","usedPercent":10,"remainingPercent":90,"resetAt":1700000000}]}
        JSON
          exit 0
        fi
        exit 1
        """
        try Data(codexScriptBody.utf8).write(to: codexScript, options: [.atomic])
        XCTAssertEqual(codexScript.path.withCString { chmod($0, 0o755) }, 0)

        let primaryJSONL = """
        {"timestamp":"2026-02-24T03:04:05Z","session_id":"sess_runtime","model":"gpt-5","usage":{"prompt_tokens":8,"completion_tokens":4,"total_tokens":12}}
        """
        try Data(primaryJSONL.utf8).write(
            to: sessionsDir.appendingPathComponent("main.jsonl"),
            options: [.atomic]
        )

        try writeOpenCodeMessage(
            homeDirectoryURL: homeDir,
            sessionID: "ses_opencode_codex",
            messageID: "msg_assistant_codex",
            payload: [
                "role": "assistant",
                "time": ["created": 1_770_000_100_000],
                "providerID": "openai",
                "modelID": "gpt-5.3-codex",
                "tokens": ["input": 6, "output": 4],
            ]
        )
        try writeOpenCodeMessage(
            homeDirectoryURL: homeDir,
            sessionID: "ses_opencode_codex",
            messageID: "msg_user_codex",
            payload: [
                "role": "user",
                "time": ["created": 1_770_000_101_000],
                "providerID": "openai",
                "modelID": "gpt-5.3-codex",
                "tokens": ["input": 999, "output": 1],
            ]
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: true, cliPathOverride: codexScript.path),
            claude: ClaudeSettings(enabled: false),
            locale: .system,
            refreshIntervalSec: 60
        )

        let track1Store = Track1Store(snapshotsURLOverride: dir.appendingPathComponent("track1.json"))
        let track2Store = Track2Store(pointsURLOverride: dir.appendingPathComponent("track2.json"))
        let widgetContainer = dir.appendingPathComponent("widget", isDirectory: true)
        let refresher = WidgetSnapshotRefresher(
            track1Store: track1Store,
            track2Store: track2Store,
            snapshotStore: WidgetSnapshotStore(containerURLOverride: widgetContainer)
        )

        let runtime = ProviderCollectionRuntime(homeDirectoryURL: homeDir)

        let snapshot = try runtime.collectTrack1Snapshot(provider: .codex, settings: settings)
        try await track1Store.append(snapshot)

        let points = try runtime.collectTrack2Points(provider: .codex)
        _ = try await runtime.persistTrack2Points(points, store: track2Store)

        let secondPassPoints = try runtime.collectTrack2Points(provider: .codex)
        XCTAssertEqual(secondPassPoints, [])
        let secondPassPersisted = try await runtime.persistTrack2Points(secondPassPoints, store: track2Store)
        XCTAssertEqual(secondPassPersisted, 0)

        try await refresher.refresh(settings: settings, now: Date(timeIntervalSince1970: 1_770_000_000))

        let persistedTrack1 = try await track1Store.loadAll()
        XCTAssertEqual(persistedTrack1.count, 1)
        XCTAssertEqual(persistedTrack1[0].provider, .codex)
        XCTAssertEqual(persistedTrack1[0].source, .cliMethodB)

        let persistedTrack2 = try await track2Store.loadAll()
        XCTAssertEqual(persistedTrack2.count, 2)
        XCTAssertTrue(persistedTrack2.allSatisfy { $0.provider == .codex })
        XCTAssertEqual(persistedTrack2.map(\ .totalTokens).compactMap { $0 }.sorted(), [10, 12])
        XCTAssertTrue(persistedTrack2.contains(where: { $0.sourceFile.hasPrefix("opencode_db:") }))
        XCTAssertFalse(persistedTrack2.contains(where: { $0.totalTokens == 1000 }))

        let widgetSnapshot = try XCTUnwrap(WidgetSnapshotStore(containerURLOverride: widgetContainer).read())
        XCTAssertEqual(widgetSnapshot.track1.count, 1)
        XCTAssertEqual(widgetSnapshot.track2.count, 1)
    }

    func testOpenCodeTrack2RowsRemainVisibleAcrossProviderCalls() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDir = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        try writeOpenCodeMessage(
            homeDirectoryURL: homeDir,
            sessionID: "ses_opencode_codex_cursor",
            messageID: "msg_assistant_codex_cursor",
            payload: [
                "role": "assistant",
                "time": ["created": 1_770_100_000_000],
                "providerID": "openai",
                "modelID": "gpt-5.3-codex",
                "tokens": ["input": 10, "output": 5],
            ]
        )

        try writeOpenCodeMessage(
            homeDirectoryURL: homeDir,
            sessionID: "ses_opencode_claude_cursor",
            messageID: "msg_assistant_claude_cursor",
            payload: [
                "role": "assistant",
                "time": ["created": 1_770_100_001_000],
                "providerID": "anthropic",
                "modelID": "claude-sonnet-4-5",
                "tokens": ["input": 9, "output": 6],
            ]
        )

        let runtime = ProviderCollectionRuntime(homeDirectoryURL: homeDir)

        let codexPoints = try runtime.collectTrack2Points(provider: .codex)
        XCTAssertEqual(codexPoints.count, 1)
        XCTAssertEqual(codexPoints[0].provider, .codex)
        XCTAssertEqual(codexPoints[0].totalTokens, 15)

        let claudePoints = try runtime.collectTrack2Points(provider: .claude)
        XCTAssertEqual(claudePoints.count, 1)
        XCTAssertEqual(claudePoints[0].provider, .claude)
        XCTAssertEqual(claudePoints[0].totalTokens, 15)
    }

    func testTrack2IncrementalFileCursorHandlesPartialJSONLAppend() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDir = dir.appendingPathComponent("home", isDirectory: true)
        let sessionsDir = homeDir.appendingPathComponent(".codex/sessions/2026-02-26", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let jsonlURL = sessionsDir.appendingPathComponent("main.jsonl")
        try Data(
            """
            {"timestamp":1770100000,"session_id":"ses_cursor","model":"gpt-5.3-codex","input_tokens":3,"output_tokens":2}
            """.appending("\n").utf8
        ).write(to: jsonlURL, options: [.atomic])

        let runtime = ProviderCollectionRuntime(homeDirectoryURL: homeDir)
        let track2Store = Track2Store(pointsURLOverride: dir.appendingPathComponent("track2.json"))

        let firstPoints = try runtime.collectTrack2Points(provider: .codex)
        XCTAssertEqual(firstPoints.count, 1)
        let firstPersisted = try await runtime.persistTrack2Points(firstPoints, store: track2Store)
        XCTAssertEqual(firstPersisted, 1)

        let secondPassPoints = try runtime.collectTrack2Points(provider: .codex)
        XCTAssertEqual(secondPassPoints, [])

        try appendText(
            """
            {"timestamp":1770100001,"session_id":"ses_cursor","input_tokens":4
            """,
            to: jsonlURL
        )
        let partialPoints = try runtime.collectTrack2Points(provider: .codex)
        XCTAssertEqual(partialPoints, [])

        try appendText(",\"output_tokens\":6}\n", to: jsonlURL)
        let appendedPoints = try runtime.collectTrack2Points(provider: .codex)
        let appendedPersisted = try await runtime.persistTrack2Points(appendedPoints, store: track2Store)
        XCTAssertEqual(appendedPersisted, 1)

        let all = try await track2Store.loadAll()
        XCTAssertEqual(all.count, 2)

        let appendedPoint = try XCTUnwrap(
            all.first(where: { Int($0.timestamp.timeIntervalSince1970) == 1_770_100_001 })
        )
        XCTAssertEqual(appendedPoint.model, "gpt-5.3-codex")
        XCTAssertEqual(appendedPoint.totalTokens, 10)
    }

    func testCollectTrack1SnapshotClaudeMethodBOAuthUsageWindowsWithPlanFromProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDir = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let claudeCLI = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 2\n".utf8).write(to: claudeCLI, options: [.atomic])
        XCTAssertEqual(claudeCLI.path.withCString { chmod($0, 0o755) }, 0)

        try writeClaudeOAuthCredentialsJSON(
            homeDirectoryURL: homeDir,
            accessToken: "token_123",
            expiresAtMs: 4_102_444_800_000
        )

        let calls = ThreadSafeArray<String>()

        let usageJSON = """
        {
          "extra_usage": {"unexpected": true},
          "five_hour": {"utilization": 12.5, "resetAt": "2026-03-01T00:00:00Z"},
          "iguana_necktie": 123,
          "seven_day": {"utilization": 45.0, "resetAt": "2026-03-02T00:00:00Z"},
          "seven_day_cowork": {"utilization": 67.0, "resetAt": "2026-03-04T00:00:00Z"},
          "seven_day_oauth_apps": {"utilization": 5.0, "resetAt": "2026-03-05T00:00:00Z"},
          "seven_day_opus": {"utilization": 80.0, "resetAt": "2026-03-03T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 33.0, "resetAt": "2026-03-06T00:00:00Z"}
        }
        """

        let runtime = ProviderCollectionRuntime(
            homeDirectoryURL: homeDir,
            processRunner: .init(run: { _, arguments, _ in
                calls.append("process \(arguments.joined(separator: " "))")
                return .init(status: 1, stdout: Data(), stderr: Data())
            }),
            httpRunner: .init(run: { request, _ in
                let url = request.url?.absoluteString ?? ""
                calls.append("http \(url)")
                if url.contains("/api/oauth/usage") {
                    return .init(statusCode: 200, body: Data(usageJSON.utf8))
                }
                if url.contains("/api/oauth/profile") {
                    return .init(
                        statusCode: 200,
                        body: Data("{\"account\":{\"has_claude_pro\":true},\"organization\":{\"organization_type\":\"personal\"}}".utf8)
                    )
                }
                return .init(statusCode: 500, body: Data())
            })
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: false),
            claude: ClaudeSettings(enabled: true, cliPathOverride: claudeCLI.path),
            locale: .system,
            refreshIntervalSec: 60
        )

        let snapshot = try runtime.collectTrack1Snapshot(provider: .claude, settings: settings)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.windows.count, 6)
        XCTAssertEqual(snapshot.windows[0].windowId, .rolling5h)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude_fivehour")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 12.5)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 87.5)
        XCTAssertEqual(snapshot.windows[1].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[1].rawScopeLabel, "claude_sevenday")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 45.0)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 55.0)
        XCTAssertEqual(snapshot.windows[2].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[2].rawScopeLabel, "claude_sevendaycowork")
        XCTAssertEqual(snapshot.windows[2].usedPercent, 67.0)
        XCTAssertEqual(snapshot.windows[2].remainingPercent, 33.0)
        XCTAssertEqual(snapshot.windows[3].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[3].rawScopeLabel, "claude_sevendayoauthapps")
        XCTAssertEqual(snapshot.windows[3].usedPercent, 5.0)
        XCTAssertEqual(snapshot.windows[3].remainingPercent, 95.0)
        XCTAssertEqual(snapshot.windows[4].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[4].rawScopeLabel, "claude_sevendayopus")
        XCTAssertEqual(snapshot.windows[4].usedPercent, 80.0)
        XCTAssertEqual(snapshot.windows[4].remainingPercent, 20.0)
        XCTAssertEqual(snapshot.windows[5].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[5].rawScopeLabel, "claude_sevendaysonnet")
        XCTAssertEqual(snapshot.windows[5].usedPercent, 33.0)
        XCTAssertEqual(snapshot.windows[5].remainingPercent, 67.0)
        XCTAssertEqual(snapshot.confidence, .high)

        let recorded = calls.snapshot()
        XCTAssertEqual(recorded.filter { $0.hasPrefix("http ") }.count, 2)
        XCTAssertTrue(recorded.contains(where: { $0.contains("/api/oauth/usage") }))
        XCTAssertTrue(recorded.contains(where: { $0.contains("/api/oauth/profile") }))
        XCTAssertFalse(recorded.contains(where: { $0.hasPrefix("process ") }))

        try writeOpenCodeMessage(
            homeDirectoryURL: homeDir,
            sessionID: "ses_opencode_claude",
            messageID: "msg_assistant_claude",
            payload: [
                "role": "assistant",
                "time": ["created": 1_770_020_000_000],
                "providerID": "anthropic",
                "modelID": "claude-sonnet-4-5",
                "tokens": ["input": 7, "output": 4],
            ]
        )
        try writeOpenCodeMessage(
            homeDirectoryURL: homeDir,
            sessionID: "ses_opencode_claude",
            messageID: "msg_user_claude",
            payload: [
                "role": "user",
                "time": ["created": 1_770_020_001_000],
                "providerID": "anthropic",
                "modelID": "claude-sonnet-4-5",
                "tokens": ["input": 600, "output": 300],
            ]
        )

        let track2Points = try runtime.collectTrack2Points(provider: .claude)
        XCTAssertEqual(track2Points.count, 1)
        XCTAssertEqual(track2Points[0].provider, .claude)
        XCTAssertEqual(track2Points[0].sessionId, "ses_opencode_claude")
        XCTAssertEqual(track2Points[0].model, "claude-sonnet-4-5")
        XCTAssertEqual(track2Points[0].promptTokens, 7)
        XCTAssertEqual(track2Points[0].completionTokens, 4)
        XCTAssertEqual(track2Points[0].totalTokens, 11)
        XCTAssertEqual(track2Points[0].confidence, .medium)
        XCTAssertEqual(track2Points[0].parserVersion, "opencode_track2_message_v1")
        XCTAssertTrue(track2Points[0].sourceFile.hasPrefix("opencode_db:"))
    }

    func testCollectTrack1SnapshotClaudeMethodBOAuthUsageWindowsWithPlanFromAuthStatusWhenProfileUnavailable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDir = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let claudeCLI = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claudeCLI, options: [.atomic])
        XCTAssertEqual(claudeCLI.path.withCString { chmod($0, 0o755) }, 0)

        try writeClaudeOAuthCredentialsJSON(
            homeDirectoryURL: homeDir,
            accessToken: "token_123",
            expiresAtMs: 4_102_444_800_000
        )

        let calls = ThreadSafeArray<String>()

        let usageJSON = """
        {
          "extra_usage": {"unexpected": true},
          "five_hour": {"utilization": 12.5, "resetAt": "2026-03-01T00:00:00Z"},
          "iguana_necktie": 123,
          "seven_day": {"utilization": 45.0, "resetAt": "2026-03-02T00:00:00Z"},
          "seven_day_cowork": {"utilization": 67.0, "resetAt": "2026-03-04T00:00:00Z"},
          "seven_day_oauth_apps": {"utilization": 5.0, "resetAt": "2026-03-05T00:00:00Z"},
          "seven_day_opus": {"utilization": 80.0, "resetAt": "2026-03-03T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 33.0, "resetAt": "2026-03-06T00:00:00Z"}
        }
        """

        let runtime = ProviderCollectionRuntime(
            homeDirectoryURL: homeDir,
            processRunner: .init(run: { _, arguments, _ in
                calls.append("process \(arguments.joined(separator: " "))")
                switch arguments {
                case ["auth", "status", "--json"]:
                    return .init(status: 0, stdout: Data("{\"subscriptionType\":\"max\"}".utf8), stderr: Data())
                default:
                    return .init(status: 1, stdout: Data(), stderr: Data())
                }
            }),
            httpRunner: .init(run: { request, _ in
                let url = request.url?.absoluteString ?? ""
                calls.append("http \(url)")
                if url.contains("/api/oauth/usage") {
                    return .init(statusCode: 200, body: Data(usageJSON.utf8))
                }
                if url.contains("/api/oauth/profile") {
                    return .init(statusCode: 503, body: Data())
                }
                return .init(statusCode: 500, body: Data())
            })
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: false),
            claude: ClaudeSettings(enabled: true, cliPathOverride: claudeCLI.path),
            locale: .system,
            refreshIntervalSec: 60
        )

        let snapshot = try runtime.collectTrack1Snapshot(provider: .claude, settings: settings)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .max)
        XCTAssertEqual(snapshot.windows.count, 6)
        XCTAssertEqual(snapshot.windows[0].windowId, .rolling5h)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude_fivehour")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 12.5)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 87.5)
        XCTAssertEqual(snapshot.windows[1].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[1].rawScopeLabel, "claude_sevenday")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 45.0)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 55.0)
        XCTAssertEqual(snapshot.windows[2].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[2].rawScopeLabel, "claude_sevendaycowork")
        XCTAssertEqual(snapshot.windows[2].usedPercent, 67.0)
        XCTAssertEqual(snapshot.windows[2].remainingPercent, 33.0)
        XCTAssertEqual(snapshot.windows[3].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[3].rawScopeLabel, "claude_sevendayoauthapps")
        XCTAssertEqual(snapshot.windows[3].usedPercent, 5.0)
        XCTAssertEqual(snapshot.windows[3].remainingPercent, 95.0)
        XCTAssertEqual(snapshot.windows[4].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[4].rawScopeLabel, "claude_sevendayopus")
        XCTAssertEqual(snapshot.windows[4].usedPercent, 80.0)
        XCTAssertEqual(snapshot.windows[4].remainingPercent, 20.0)
        XCTAssertEqual(snapshot.windows[5].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[5].rawScopeLabel, "claude_sevendaysonnet")
        XCTAssertEqual(snapshot.windows[5].usedPercent, 33.0)
        XCTAssertEqual(snapshot.windows[5].remainingPercent, 67.0)
        XCTAssertEqual(snapshot.confidence, .high)

        let recorded = calls.snapshot()
        XCTAssertEqual(recorded.filter { $0.hasPrefix("http ") }.count, 2)
        XCTAssertTrue(recorded.contains(where: { $0.contains("/api/oauth/usage") }))
        XCTAssertTrue(recorded.contains(where: { $0.contains("/api/oauth/profile") }))
        XCTAssertTrue(recorded.contains(where: { $0 == "process auth status --json" }))

        let firstUsageIndex = recorded.firstIndex(where: { $0.contains("/api/oauth/usage") })
        let firstProfileIndex = recorded.firstIndex(where: { $0.contains("/api/oauth/profile") })
        let firstProcessIndex = recorded.firstIndex(where: { $0 == "process auth status --json" })
        XCTAssertNotNil(firstUsageIndex)
        XCTAssertNotNil(firstProfileIndex)
        XCTAssertNotNil(firstProcessIndex)
        if let firstUsageIndex, let firstProfileIndex, let firstProcessIndex {
            XCTAssertLessThan(firstUsageIndex, firstProfileIndex)
            XCTAssertLessThan(firstProfileIndex, firstProcessIndex)
        }
    }

    func testCollectTrack1SnapshotClaudeMethodBOAuthProfileUsedWhenUsageUnavailable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDir = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let claudeCLI = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 2\n".utf8).write(to: claudeCLI, options: [.atomic])
        XCTAssertEqual(claudeCLI.path.withCString { chmod($0, 0o755) }, 0)

        try writeClaudeOAuthCredentialsJSON(
            homeDirectoryURL: homeDir,
            accessToken: "token_123",
            expiresAtMs: 4_102_444_800_000
        )

        let calls = ThreadSafeArray<String>()

        let runtime = ProviderCollectionRuntime(
            homeDirectoryURL: homeDir,
            processRunner: .init(run: { _, arguments, _ in
                calls.append("process \(arguments.joined(separator: " "))")
                return .init(status: 1, stdout: Data(), stderr: Data())
            }),
            httpRunner: .init(run: { request, _ in
                let url = request.url?.absoluteString ?? ""
                calls.append("http \(url)")
                if url.contains("/api/oauth/usage") {
                    return .init(statusCode: 503, body: Data())
                }
                if url.contains("/api/oauth/profile") {
                    return .init(
                        statusCode: 200,
                        body: Data("{\"account\":{\"has_claude_pro\":true},\"organization\":{\"organization_type\":\"personal\"}}".utf8)
                    )
                }
                return .init(statusCode: 500, body: Data())
            })
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: false),
            claude: ClaudeSettings(enabled: true, cliPathOverride: claudeCLI.path),
            locale: .system,
            refreshIntervalSec: 60
        )

        let snapshot = try runtime.collectTrack1Snapshot(provider: .claude, settings: settings)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude")
        XCTAssertEqual(snapshot.confidence, .medium)

        let recorded = calls.snapshot()
        XCTAssertEqual(recorded.filter { $0.hasPrefix("http ") }.count, 2)
        XCTAssertTrue(recorded.contains(where: { $0.contains("/api/oauth/usage") }))
        XCTAssertTrue(recorded.contains(where: { $0.contains("/api/oauth/profile") }))
        XCTAssertFalse(recorded.contains(where: { $0.hasPrefix("process ") }))
    }

    func testCollectTrack1SnapshotClaudeMethodBFallsBackToAuthStatusWhenOAuthUnavailable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeDir = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let claudeCLI = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claudeCLI, options: [.atomic])
        XCTAssertEqual(claudeCLI.path.withCString { chmod($0, 0o755) }, 0)

        try writeClaudeOAuthCredentialsJSON(
            homeDirectoryURL: homeDir,
            accessToken: "token_123",
            expiresAtMs: 4_102_444_800_000
        )

        let calls = ThreadSafeArray<String>()

        let runtime = ProviderCollectionRuntime(
            homeDirectoryURL: homeDir,
            processRunner: .init(run: { _, arguments, _ in
                calls.append("process \(arguments.joined(separator: " "))")
                switch arguments {
                case ["auth", "status", "--json"]:
                    return .init(status: 0, stdout: Data("{\"subscriptionType\":\"max\"}".utf8), stderr: Data())
                default:
                    return .init(status: 1, stdout: Data(), stderr: Data())
                }
            }),
            httpRunner: .init(run: { request, _ in
                let url = request.url?.absoluteString ?? ""
                calls.append("http \(url)")
                return .init(statusCode: 503, body: Data())
            })
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: false),
            claude: ClaudeSettings(enabled: true, cliPathOverride: claudeCLI.path),
            locale: .system,
            refreshIntervalSec: 60
        )

        let snapshot = try runtime.collectTrack1Snapshot(provider: .claude, settings: settings)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .max)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude")
        XCTAssertEqual(snapshot.confidence, .medium)

        let recorded = calls.snapshot()
        XCTAssertEqual(recorded.filter { $0.hasPrefix("http ") }.count, 2)
        XCTAssertTrue(recorded.contains(where: { $0.contains("/api/oauth/usage") }))
        XCTAssertTrue(recorded.contains(where: { $0.contains("/api/oauth/profile") }))
        XCTAssertTrue(recorded.contains(where: { $0 == "process auth status --json" }))
    }

    func testCollectTrack1SnapshotClaudeFallsBackToAuthStatusJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let claudeCLI = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claudeCLI, options: [.atomic])
        XCTAssertEqual(claudeCLI.path.withCString { chmod($0, 0o755) }, 0)

        let runtime = ProviderCollectionRuntime(
            homeDirectoryURL: dir,
            processRunner: .init(run: { _, arguments, _ in
                switch arguments {
                case ["usage", "--json"], ["status", "--json"], ["account", "--json"]:
                    return .init(status: 2, stdout: Data(), stderr: Data("unsupported".utf8))
                case ["auth", "status", "--json"]:
                    return .init(
                        status: 0,
                        stdout: Data("{\"subscriptionType\":\"max\"}".utf8),
                        stderr: Data()
                    )
                default:
                    return .init(status: 1, stdout: Data(), stderr: Data())
                }
            })
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: false),
            claude: ClaudeSettings(enabled: true, cliPathOverride: claudeCLI.path),
            locale: .system,
            refreshIntervalSec: 60
        )

        let snapshot = try runtime.collectTrack1Snapshot(provider: .claude, settings: settings)
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .max)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "claude")
        XCTAssertEqual(snapshot.confidence, .medium)
    }

    func testCollectTrack1SnapshotCodexFallsBackToAppServerRateLimitsBeforeJWTPlan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexRoot = dir.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)

        let codexCLI = dir.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codexCLI, options: [.atomic])
        XCTAssertEqual(codexCLI.path.withCString { chmod($0, 0o755) }, 0)

        let jwt = try makeUnsignedJWT(payload: ["chatgpt_plan_type": "chatgpt_plus"])
        let authJSON = """
        {
          "tokens": {
            "id_token": "\(jwt)"
          }
        }
        """
        try Data(authJSON.utf8).write(to: codexRoot.appendingPathComponent("auth.json"), options: [.atomic])

        let runtime = ProviderCollectionRuntime(
            homeDirectoryURL: dir,
            processRunner: .init(run: { _, arguments, stdinData in
                switch arguments {
                case ["usage", "--json"], ["status", "--json"], ["limits", "--json"]:
                    return .init(status: 2, stdout: Data(), stderr: Data("unsupported".utf8))
                case ["app-server"]:
                    let stdinText = String(data: stdinData ?? Data(), encoding: .utf8) ?? ""

                    func extractMethods(from jsonl: String) -> [String] {
                        var methods: [String] = []
                        for line in jsonl.split(whereSeparator: \.isNewline) {
                            guard let data = line.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data),
                                  let dict = json as? [String: Any],
                                  let method = dict["method"] as? String
                            else {
                                continue
                            }
                            methods.append(method)
                        }
                        return methods
                    }

                    func paramsIsNull(for methodName: String, in jsonl: String) -> Bool {
                        for line in jsonl.split(whereSeparator: \.isNewline) {
                            guard let data = line.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data),
                                  let dict = json as? [String: Any],
                                  (dict["method"] as? String) == methodName
                            else {
                                continue
                            }
                            return dict["params"] is NSNull
                        }
                        return false
                    }

                    let methods = extractMethods(from: stdinText)
                    XCTAssertTrue(methods.contains("initialize"))
                    XCTAssertTrue(methods.contains("account/rateLimits/read"))
                    XCTAssertTrue(paramsIsNull(for: "account/rateLimits/read", in: stdinText))

                    let response = """
                    {"jsonrpc":"2.0","id":1,"result":{"ok":true}}
                    {"jsonrpc":"2.0","id":2,"result":{"planType":"chatgpt_pro","primary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":"2026-03-01T00:00:00Z"},"secondary":{"usedPercent":15,"remainingPercent":85,"resetsAt":1700000000}}}
                    """
                    return .init(status: 0, stdout: Data(response.utf8), stderr: Data())
                default:
                    return .init(status: 1, stdout: Data(), stderr: Data())
                }
            })
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: true, cliPathOverride: codexCLI.path),
            claude: ClaudeSettings(enabled: false),
            locale: .system,
            refreshIntervalSec: 60
        )

        let snapshot = try runtime.collectTrack1Snapshot(provider: .codex, settings: settings)
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "codex_primary")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 42)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 58)
        XCTAssertEqual(snapshot.windows[1].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[1].rawScopeLabel, "codex_secondary")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 15)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 85)
        XCTAssertEqual(snapshot.confidence, .high)
    }

    func testCollectTrack1SnapshotCodexFallsBackToNestedAppServerRateLimitsShape() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexRoot = dir.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)

        let codexCLI = dir.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codexCLI, options: [.atomic])
        XCTAssertEqual(codexCLI.path.withCString { chmod($0, 0o755) }, 0)

        let jwt = try makeUnsignedJWT(payload: ["chatgpt_plan_type": "chatgpt_plus"])
        let authJSON = """
        {
          "tokens": {
            "id_token": "\(jwt)"
          }
        }
        """
        try Data(authJSON.utf8).write(to: codexRoot.appendingPathComponent("auth.json"), options: [.atomic])

        let runtime = ProviderCollectionRuntime(
            homeDirectoryURL: dir,
            processRunner: .init(run: { _, arguments, _ in
                switch arguments {
                case ["usage", "--json"], ["status", "--json"], ["limits", "--json"]:
                    return .init(status: 2, stdout: Data(), stderr: Data("unsupported".utf8))
                case ["app-server"]:
                    let response = """
                    {"jsonrpc":"2.0","id":1,"result":{"ok":true}}
                    {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":64,"resetsAt":"2026-03-02T00:00:00Z","windowDurationMins":10080},"secondary":{"usedPercent":25,"remainingPercent":75,"resetsAt":1700000000}}}}
                    """
                    return .init(status: 0, stdout: Data(response.utf8), stderr: Data())
                default:
                    return .init(status: 1, stdout: Data(), stderr: Data())
                }
            })
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: true, cliPathOverride: codexCLI.path),
            claude: ClaudeSettings(enabled: false),
            locale: .system,
            refreshIntervalSec: 60
        )

        let snapshot = try runtime.collectTrack1Snapshot(provider: .codex, settings: settings)
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .pro)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "codex_primary")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 64)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 36)
        XCTAssertEqual(snapshot.windows[1].windowId, .modelSpecific)
        XCTAssertEqual(snapshot.windows[1].rawScopeLabel, "codex_secondary")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 25)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 75)
        XCTAssertEqual(snapshot.confidence, .high)
    }

    func testCollectTrack1SnapshotCodexFallsBackToLocalAuthJWTPlan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexRoot = dir.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)

        let codexCLI = dir.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codexCLI, options: [.atomic])
        XCTAssertEqual(codexCLI.path.withCString { chmod($0, 0o755) }, 0)

        let jwt = try makeUnsignedJWT(payload: ["chatgpt_plan_type": "chatgpt_plus"])
        let authJSON = """
        {
          "tokens": {
            "id_token": "\(jwt)"
          }
        }
        """
        try Data(authJSON.utf8).write(to: codexRoot.appendingPathComponent("auth.json"), options: [.atomic])

        let runtime = ProviderCollectionRuntime(
            homeDirectoryURL: dir,
            processRunner: .init(run: { _, arguments, _ in
                switch arguments {
                case ["usage", "--json"], ["status", "--json"], ["limits", "--json"]:
                    return .init(status: 2, stdout: Data(), stderr: Data("unsupported".utf8))
                default:
                    return .init(status: 1, stdout: Data(), stderr: Data())
                }
            })
        )

        let settings = AppSettings(
            codex: CodexSettings(enabled: true, cliPathOverride: codexCLI.path),
            claude: ClaudeSettings(enabled: false),
            locale: .system,
            refreshIntervalSec: 60
        )

        let snapshot = try runtime.collectTrack1Snapshot(provider: .codex, settings: settings)
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.source, .cliMethodB)
        XCTAssertEqual(snapshot.plan, .plus)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].windowId, .weekly)
        XCTAssertEqual(snapshot.windows[0].rawScopeLabel, "codex")
        XCTAssertEqual(snapshot.confidence, .medium)
    }

    func testTrack2StoreInsertReadIsolation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let track1URL = dir.appendingPathComponent("track1.json")
        let track2URL = dir.appendingPathComponent("track2.json")

        let track2Store = Track2Store(pointsURLOverride: track2URL)
        let point = Track2TimelinePoint(
            provider: .claude,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            sessionId: "session_123",
            model: "claude-3",
            promptTokens: 10,
            completionTokens: 20,
            totalTokens: 30,
            sourceFile: "secondary_local:projects/sample.jsonl",
            confidence: .low,
            parserVersion: "t2_fixture_v1"
        )

        try await track2Store.append(point)
        let track2Loaded = try await track2Store.loadAll()
        XCTAssertEqual(track2Loaded, [point])

        let track1Store = Track1Store(snapshotsURLOverride: track1URL)
        let track1Loaded = try await track1Store.loadAll()
        XCTAssertEqual(track1Loaded, [])
    }

    func testTrack2StoreInvalidatesCacheWhenFileChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let track2URL = dir.appendingPathComponent("track2.json")
        let storeA = Track2Store(pointsURLOverride: track2URL)
        let storeB = Track2Store(pointsURLOverride: track2URL)

        let oldPoint = Track2TimelinePoint(
            provider: .codex,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            sessionId: "session_old",
            model: "gpt-5-codex",
            promptTokens: 100,
            completionTokens: 50,
            totalTokens: 150,
            sourceFile: "opencode_db:old",
            confidence: .medium,
            parserVersion: "t2_fixture_v1"
        )
        let newPoint = Track2TimelinePoint(
            provider: .codex,
            timestamp: Date(timeIntervalSince1970: 1_700_000_600),
            sessionId: "session_new",
            model: "gpt-5.3-codex",
            promptTokens: 120,
            completionTokens: 80,
            totalTokens: 200,
            sourceFile: "opencode_db:new",
            confidence: .medium,
            parserVersion: "t2_fixture_v1"
        )

        try await storeA.replaceAll([oldPoint])
        let initialPoints = try await storeA.loadAll()
        XCTAssertEqual(initialPoints, [oldPoint])

        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await storeB.replaceAll([newPoint])

        let refreshedPoints = try await storeA.loadAll()
        XCTAssertEqual(refreshedPoints, [newPoint])
    }

    func testTrack1StoreInvalidatesCacheWhenFileChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let track1URL = dir.appendingPathComponent("track1.json")
        let storeA = Track1Store(snapshotsURLOverride: track1URL)
        let storeB = Track1Store(snapshotsURLOverride: track1URL)

        let oldSnapshot = Track1Snapshot(
            provider: .claude,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .cliMethodB,
            plan: .unknown,
            windows: [
                Track1Window(
                    windowId: .rolling5h,
                    usedPercent: 12,
                    remainingPercent: 88,
                    resetAt: Date(timeIntervalSince1970: 1_700_000_900),
                    rawScopeLabel: "rolling_5h"
                ),
            ],
            confidence: .medium,
            parserVersion: "t1_fixture_v1"
        )

        let newSnapshot = Track1Snapshot(
            provider: .claude,
            observedAt: Date(timeIntervalSince1970: 1_700_000_600),
            source: .cliMethodB,
            plan: .pro,
            windows: [
                Track1Window(
                    windowId: .rolling5h,
                    usedPercent: 44,
                    remainingPercent: 56,
                    resetAt: Date(timeIntervalSince1970: 1_700_001_200),
                    rawScopeLabel: "rolling_5h"
                ),
            ],
            confidence: .high,
            parserVersion: "t1_fixture_v1"
        )

        try await storeA.replaceAll([oldSnapshot])
        let initialSnapshots = try await storeA.loadAll()
        XCTAssertEqual(initialSnapshots, [oldSnapshot])

        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await storeB.replaceAll([newSnapshot])

        let refreshedSnapshots = try await storeA.loadAll()
        XCTAssertEqual(refreshedSnapshots, [newSnapshot])
    }

    func testNoMergeHelperAPIExposure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let track1URL = dir.appendingPathComponent("track1.json")
        let track2URL = dir.appendingPathComponent("track2.json")

        let track1Store = Track1Store(snapshotsURLOverride: track1URL)
        let track2Store = Track2Store(pointsURLOverride: track2URL)

        try await track1Store.append(
            Track1Snapshot(
                provider: .codex,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                source: .cliMethodB,
                plan: .unknown,
                windows: [
                    Track1Window(
                        windowId: .weekly,
                        usedPercent: nil,
                        remainingPercent: nil,
                        resetAt: nil,
                        rawScopeLabel: "codex"
                    )
                ],
                confidence: .high,
                parserVersion: "t1_fixture_v1"
            )
        )

        try await track2Store.append(
            Track2TimelinePoint(
                provider: .claude,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                sessionId: "session_123",
                model: "claude-3",
                promptTokens: 10,
                completionTokens: 20,
                totalTokens: 30,
                sourceFile: "secondary_local:projects/sample.jsonl",
                confidence: .low,
                parserVersion: "t2_fixture_v1"
            )
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let track1Data = try Data(contentsOf: track1URL)
        XCTAssertThrowsError(try decoder.decode([Track2TimelinePoint].self, from: track1Data))

        let track2Data = try Data(contentsOf: track2URL)
        XCTAssertThrowsError(try decoder.decode([Track1Snapshot].self, from: track2Data))
    }

    func testDiagnosticsRedactsBearerInMessageAndExport() {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DiagnosticsStore(maxEventsPerProvider: 50, now: { fixedNow })

        let secret = "abc.def.ghi"
        let logger = DiagnosticsLogger(provider: .claude, store: store)
        logger.info("Authorization: Bearer \(secret)")

        let export = store.exportProviderNDJSON(provider: .claude)
        let text = String(data: export.data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("<redacted:bearer:"))
    }

    func testDiagnosticsExportDoesNotContainPlaintextCookieOrQuerySecrets() {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DiagnosticsStore(maxEventsPerProvider: 50, now: { fixedNow })

        let cookieSecret = "SESSION_TOKEN_123"
        let querySecret = "ACCESS_TOKEN_456"

        let logger = DiagnosticsLogger(provider: .codex, store: store)
        logger.info("Cookie: sessionid=\(cookieSecret); theme=light")
        logger.info("https://example.com/cb?access_token=\(querySecret)&state=ok")

        let export = store.exportProviderNDJSON(provider: .codex)
        let text = String(data: export.data, encoding: .utf8) ?? ""

        XCTAssertFalse(text.contains(cookieSecret))
        XCTAssertFalse(text.contains(querySecret))
        XCTAssertTrue(text.contains("<redacted:cookie:"))
        XCTAssertTrue(text.contains("<redacted:token:"))
    }

    func testProviderScopedEntriesPreservedWhileRedactingFields() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DiagnosticsStore(maxEventsPerProvider: 50, now: { fixedNow })

        let tokenA = "tok_A_123"
        let tokenB = "tok_B_456"

        DiagnosticsLogger(provider: .claude, store: store).info(
            "request",
            fields: [
                "authorization": .string("Bearer \(tokenA)"),
                "nested": .object([
                    "access_token": .string(tokenA),
                    "ok": .string("hello"),
                ]),
            ]
        )

        DiagnosticsLogger(provider: .codex, store: store).info(
            "request",
            fields: [
                "x-api-key": .string(tokenB),
            ]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let claudeExport = store.exportProviderNDJSON(provider: .claude)
        let codexExport = store.exportProviderNDJSON(provider: .codex)

        let claudeText = String(data: claudeExport.data, encoding: .utf8) ?? ""
        let codexText = String(data: codexExport.data, encoding: .utf8) ?? ""

        XCTAssertFalse(claudeText.contains(tokenA))
        XCTAssertFalse(codexText.contains(tokenB))

        XCTAssertFalse(claudeText.contains("\"provider\":\"codex\""))
        XCTAssertFalse(codexText.contains("\"provider\":\"claude\""))

        let claudeEvents = try decodeNDJSONEvents(claudeExport.data, decoder: decoder)
        let codexEvents = try decodeNDJSONEvents(codexExport.data, decoder: decoder)

        XCTAssertEqual(claudeEvents.count, 1)
        XCTAssertEqual(codexEvents.count, 1)
        XCTAssertEqual(claudeEvents[0].provider, .claude)
        XCTAssertEqual(codexEvents[0].provider, .codex)
    }

    func testDiagnosticsRedactorSensitiveKeyTagsAreDeterministic() {
        let redactor = DiagnosticsRedactor()

        let redacted = redactor.redactFields(
            [
                "x-api-key": .string("secret_1"),
                "api_key": .int(123),
                "password": .string("pw"),
                "nested": .object(["access_token": .string("secret_1")]),
            ]
        )

        guard case .string(let apiKeyA) = redacted["x-api-key"] else {
            XCTFail("Expected x-api-key to be redacted as string")
            return
        }
        guard case .string(let apiKeyB) = redacted["api_key"] else {
            XCTFail("Expected api_key to be redacted as string")
            return
        }
        guard case .string(let password) = redacted["password"] else {
            XCTFail("Expected password to be redacted as string")
            return
        }
        guard case .object(let nested) = redacted["nested"], case .string(let token) = nested["access_token"] else {
            XCTFail("Expected nested.access_token to be redacted as string")
            return
        }

        XCTAssertTrue(apiKeyA.hasPrefix("<redacted:apiKey:"))
        XCTAssertTrue(apiKeyB.hasPrefix("<redacted:apiKey:"))
        XCTAssertTrue(password.hasPrefix("<redacted:password:"))
        XCTAssertTrue(token.hasPrefix("<redacted:token:"))

        func extractHash(_ tag: String) -> String? {
            let trimmed = tag.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let parts = trimmed.split(separator: ":")
            guard parts.count == 3 else { return nil }
            return String(parts[2])
        }

        let hashA = extractHash(apiKeyA)
        let hashToken = extractHash(token)
        XCTAssertEqual(hashA?.count, 8)
        XCTAssertEqual(hashToken?.count, 8)

        XCTAssertEqual(hashA, hashToken)
    }


    private func decodeNDJSONEvents(_ data: Data, decoder: JSONDecoder) throws -> [DiagnosticsEvent] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var out: [DiagnosticsEvent] = []
        out.reserveCapacity(lines.count)

        for line in lines {
            out.append(try decoder.decode(DiagnosticsEvent.self, from: Data(line.utf8)))
        }
        return out
    }

    private func fixtureData(_ fileName: String) throws -> Data {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        let resource: String
        let ext: String?
        if parts.count >= 2 {
            resource = parts.dropLast().joined(separator: ".")
            ext = String(parts.last ?? "")
        } else {
            resource = fileName
            ext = nil
        }

        let bundle = Bundle(for: TokenMeterTests.self)
        guard let url = bundle.url(forResource: resource, withExtension: ext) else {
            throw NSError(
                domain: "TokenMeterTests.Fixtures",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing fixture: \(fileName)"]
            )
        }
        return try Data(contentsOf: url)
    }

    private func fixtureText(_ fileName: String) throws -> String {
        let data = try fixtureData(fileName)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeUnsignedJWT(payload: [String: String]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return "\(base64URLEncode(header)).\(base64URLEncode(payloadData))."
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class testGenerateNativeUIEvidencePNGs: XCTestCase {
    @MainActor
    func testGenerateNativeUIEvidencePNGs() async throws {
        if shouldWriteUIEvidencePNGs() == false {
            let env = ProcessInfo.processInfo.environment
            let direct = env["TOKEN_METER_WRITE_UI_EVIDENCE"] ?? "(nil)"
            let cfgKey = env.keys.first(where: { $0.lowercased().contains("xctestconfiguration") }) ?? "(none)"
            let cfg =
                env["XCTestConfigurationFilePath"]
                ?? env[cfgKey]
                ?? env.values.first(where: { $0.lowercased().contains(".xctestconfiguration") })
                ?? "(nil)"
            print("TOKEN_METER_WRITE_UI_EVIDENCE (direct)=\(direct)")
            print("XCTestConfiguration hint key=\(cfgKey)")
            print("XCTestConfiguration hint value=\(cfg)")
            throw XCTSkip("Set TOKEN_METER_WRITE_UI_EVIDENCE=1 to overwrite .sisyphus/evidence/*.png")
        }

        let root = projectRootURL()
        let evidenceDir = root.appendingPathComponent(".sisyphus", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)

        let appSupportBase = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let tokenMeterSupport = appSupportBase.appendingPathComponent("TokenMeter", isDirectory: true)
        let settingsURL = tokenMeterSupport.appendingPathComponent("settings.json")
        let track1URL = tokenMeterSupport.appendingPathComponent("track1.json")
        let track2URL = tokenMeterSupport.appendingPathComponent("track2.json")

        let backup = EvidenceStoreBackup(
            settings: readIfExists(url: settingsURL),
            track1: readIfExists(url: track1URL),
            track2: readIfExists(url: track2URL)
        )
        defer {
            restoreFile(url: settingsURL, backupData: backup.settings)
            restoreFile(url: track1URL, backupData: backup.track1)
            restoreFile(url: track2URL, backupData: backup.track2)
        }

        let now = Date()
        let parserVersion = "ui_evidence_v1"

        func seed(settings: AppSettings, track1: [Track1Snapshot], track2: [Track2TimelinePoint]) async throws {
            try await SettingsStore.shared.save(settings)
            try await Track1Store().replaceAll(track1)
            try await Track2Store().replaceAll(track2)
        }

        func writeEvidencePNG<V: View>(
            name: String,
            view: V,
            size: CGSize,
            settleSeconds: TimeInterval,
            minBytes: Int,
            minPixelsWide: Int,
            minPixelsHigh: Int
        ) throws {
            let png = try renderNativePNG(view: view, size: size, settleSeconds: settleSeconds)
            try assertNonTrivialPNG(png, minBytes: minBytes, minPixelsWide: minPixelsWide, minPixelsHigh: minPixelsHigh)
            let url = evidenceDir.appendingPathComponent(name)
            try png.write(to: url, options: [.atomic])
        }

        let contentSize = CGSize(width: 420, height: 720)
        let settingsSize = CGSize(width: 560, height: 820)

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = true

            let offsetsHours: [Double] = [22, 18, 14, 10, 6, 2]
            var points: [Track2TimelinePoint] = []
            points.reserveCapacity(offsetsHours.count * 2)

            func addSeries(provider: ProviderId, model: String, baseTokens: Int) {
                for (idx, h) in offsetsHours.enumerated() {
                    points.append(
                        Track2TimelinePoint(
                            provider: provider,
                            timestamp: now.addingTimeInterval(-h * 60 * 60),
                            sessionId: "sess_\(provider.rawValue)_\(idx)",
                            model: model,
                            promptTokens: nil,
                            completionTokens: nil,
                            totalTokens: baseTokens + (idx * 250),
                            sourceFile: "evidence/track2.jsonl",
                            confidence: .medium,
                            parserVersion: parserVersion
                        )
                    )
                }
            }

            addSeries(provider: .codex, model: "gpt-5", baseTokens: 1200)
            addSeries(provider: .claude, model: "claude-3-7-sonnet", baseTokens: 900)

            try await seed(settings: settings, track1: [], track2: points)
            try writeEvidencePNG(
                name: "task-16-chart-24h.png",
                view: ContentView(),
                size: contentSize,
                settleSeconds: 0.8,
                minBytes: 20_000,
                minPixelsWide: 200,
                minPixelsHigh: 200
            )
        }

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = true

            try await seed(settings: settings, track1: [], track2: [])
            try writeEvidencePNG(
                name: "task-16-chart-empty.png",
                view: ContentView(),
                size: contentSize,
                settleSeconds: 0.8,
                minBytes: 12_000,
                minPixelsWide: 200,
                minPixelsHigh: 200
            )
        }

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = false

            let snapshot = Track1Snapshot(
                provider: .codex,
                observedAt: now.addingTimeInterval(-5),
                source: .cliMethodB,
                plan: .pro,
                windows: [
                    Track1Window(
                        windowId: .weekly,
                        usedPercent: 25.0,
                        remainingPercent: 75.0,
                        resetAt: now.addingTimeInterval(36 * 60 * 60),
                        rawScopeLabel: "codex"
                    )
                ],
                confidence: .high,
                parserVersion: parserVersion
            )

            try await seed(settings: settings, track1: [snapshot], track2: [])
            try writeEvidencePNG(
                name: "task-17-plan-known.png",
                view: ContentView(),
                size: contentSize,
                settleSeconds: 0.8,
                minBytes: 12_000,
                minPixelsWide: 200,
                minPixelsHigh: 200
            )
        }

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = false

            let snapshot = Track1Snapshot(
                provider: .codex,
                observedAt: now.addingTimeInterval(-5),
                source: .cliMethodB,
                plan: .unknown,
                windows: [
                    Track1Window(
                        windowId: .weekly,
                        usedPercent: 10.0,
                        remainingPercent: 90.0,
                        resetAt: now.addingTimeInterval(48 * 60 * 60),
                        rawScopeLabel: "codex"
                    )
                ],
                confidence: .high,
                parserVersion: parserVersion
            )

            try await seed(settings: settings, track1: [snapshot], track2: [])
            try writeEvidencePNG(
                name: "task-17-plan-unknown.png",
                view: ContentView(),
                size: contentSize,
                settleSeconds: 0.8,
                minBytes: 12_000,
                minPixelsWide: 200,
                minPixelsHigh: 200
            )
        }

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = true

            try await seed(settings: settings, track1: [], track2: [])
            try writeEvidencePNG(
                name: "task-14-track-separation.png",
                view: ContentView(),
                size: contentSize,
                settleSeconds: 0.8,
                minBytes: 12_000,
                minPixelsWide: 200,
                minPixelsHigh: 200
            )
        }

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = false

            let okWindow = Track1Window(
                windowId: .weekly,
                usedPercent: 35.0,
                remainingPercent: 65.0,
                resetAt: now.addingTimeInterval(36 * 60 * 60),
                rawScopeLabel: "codex"
            )
            let degradedWindow = Track1Window(
                windowId: .rolling5h,
                usedPercent: nil,
                remainingPercent: nil,
                resetAt: nil,
                rawScopeLabel: "codex"
            )
            let snapshot = Track1Snapshot(
                provider: .codex,
                observedAt: now.addingTimeInterval(-90),
                source: .cliMethodB,
                plan: .pro,
                windows: [okWindow, degradedWindow],
                confidence: .medium,
                parserVersion: parserVersion
            )

            try await seed(settings: settings, track1: [snapshot], track2: [])
            try writeEvidencePNG(
                name: "task-14-partial-degrade.png",
                view: ContentView(),
                size: contentSize,
                settleSeconds: 0.8,
                minBytes: 12_000,
                minPixelsWide: 200,
                minPixelsHigh: 200
            )
        }

        DiagnosticsStore.shared.clearAll()

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = true
            settings.claude.allowMethodC = false
            settings.codex.cliPathOverride = nil
            settings.claude.cliPathOverride = nil
            settings.locale = .system
            try await seed(settings: settings, track1: [], track2: [])

            let appLocale = AppLocaleController(initialSetting: .system, loadFromStore: false)
            try writeEvidencePNG(
                name: "task-15-settings-policy.png",
                view: SettingsView().environmentObject(appLocale),
                size: settingsSize,
                settleSeconds: 1.0,
                minBytes: 18_000,
                minPixelsWide: 250,
                minPixelsHigh: 250
            )
        }

        do {
            let badDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("token-meter-evidence-override-dir", isDirectory: true)
            try? FileManager.default.removeItem(at: badDir)
            try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)

            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = true
            settings.codex.cliPathOverride = badDir.path
            settings.claude.cliPathOverride = nil
            try await seed(settings: settings, track1: [], track2: [])

            let appLocale = AppLocaleController(initialSetting: .system, loadFromStore: false)
            try writeEvidencePNG(
                name: "task-15-path-validation.png",
                view: SettingsView().environmentObject(appLocale),
                size: settingsSize,
                settleSeconds: 1.2,
                minBytes: 18_000,
                minPixelsWide: 250,
                minPixelsHigh: 250
            )
        }

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = true
            settings.claude.allowMethodC = true
            settings.claude.track1Source = .methodB
            try await seed(settings: settings, track1: [], track2: [])

            let appLocale = AppLocaleController(initialSetting: .system, loadFromStore: false)
            try writeEvidencePNG(
                name: "task-9-methodc-enabled.png",
                view: SettingsView().environmentObject(appLocale),
                size: settingsSize,
                settleSeconds: 1.0,
                minBytes: 18_000,
                minPixelsWide: 250,
                minPixelsHigh: 250
            )
        }

        do {
            var settings = AppSettings()
            settings.codex.enabled = true
            settings.claude.enabled = true
            settings.locale = .fixed("ko")
            try await seed(settings: settings, track1: [], track2: [])

            let appLocale = AppLocaleController(initialSetting: .system, loadFromStore: false)
            try writeEvidencePNG(
                name: "task-4-locale-switch.png",
                view: SettingsView().environmentObject(appLocale),
                size: settingsSize,
                settleSeconds: 1.0,
                minBytes: 18_000,
                minPixelsWide: 250,
                minPixelsHigh: 250
            )
        }

        appendLearningNote(root: root)
    }
}

private func shouldWriteUIEvidencePNGs() -> Bool {
    let markerURL = projectRootURL()
        .appendingPathComponent(".sisyphus", isDirectory: true)
        .appendingPathComponent("evidence", isDirectory: true)
        .appendingPathComponent(".write-ui-evidence")
    if FileManager.default.fileExists(atPath: markerURL.path) {
        return true
    }

    if ProcessInfo.processInfo.environment["TOKEN_METER_WRITE_UI_EVIDENCE"] == "1" {
        return true
    }

    if parentEnvironmentContainsEvidenceFlag() {
        return true
    }

    if xcodebuildEnvironmentContainsEvidenceFlag() {
        return true
    }

    let env = ProcessInfo.processInfo.environment
    let configPath =
        env["XCTestConfigurationFilePath"]
        ?? env.first(where: { $0.key.lowercased().contains("xctestconfiguration") })?.value
        ?? env.first(where: { $0.value.lowercased().contains(".xctestconfiguration") })?.value

    guard let configPath else { return false }

    let url = URL(fileURLWithPath: configPath)
    guard let data = try? Data(contentsOf: url) else { return false }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
        return false
    }

    let v = findStringValue(in: plist, key: "TOKEN_METER_WRITE_UI_EVIDENCE")
    return v == "1"
}

private func parentEnvironmentContainsEvidenceFlag() -> Bool {
    let pid = getppid()
    if pid <= 1 { return false }

    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size: size_t = 0
    if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 { return false }
    if size == 0 { return false }

    var buffer = [UInt8](repeating: 0, count: size)
    if sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) != 0 { return false }

    let pattern = Array("TOKEN_METER_WRITE_UI_EVIDENCE=1".utf8)
    if pattern.isEmpty { return false }
    if buffer.count < pattern.count { return false }

    var i = 0
    while i + pattern.count <= buffer.count {
        var matches = true
        var j = 0
        while j < pattern.count {
            if buffer[i + j] != pattern[j] {
                matches = false
                break
            }
            j += 1
        }
        if matches { return true }
        i += 1
    }

    return false
}

private func xcodebuildEnvironmentContainsEvidenceFlag() -> Bool {
    guard let pids = pidsForProcess(named: "xcodebuild"), pids.isEmpty == false else {
        return false
    }
    for pid in pids {
        if processEnvironmentContainsEvidenceFlag(pid: pid) {
            return true
        }
    }
    return false
}

private func pidsForProcess(named name: String) -> [pid_t]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", name]

    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    if process.terminationStatus != 0 {
        return []
    }

    let data = out.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    let ids: [pid_t] = text
        .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" })
        .compactMap { Int32($0) }
    return ids
}

private func processEnvironmentContainsEvidenceFlag(pid: pid_t) -> Bool {
    if pid <= 1 { return false }

    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size: size_t = 0
    if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 { return false }
    if size == 0 { return false }

    var buffer = [UInt8](repeating: 0, count: size)
    if sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) != 0 { return false }

    let pattern = Array("TOKEN_METER_WRITE_UI_EVIDENCE=1".utf8)
    if pattern.isEmpty { return false }
    if buffer.count < pattern.count { return false }

    var i = 0
    while i + pattern.count <= buffer.count {
        var matches = true
        var j = 0
        while j < pattern.count {
            if buffer[i + j] != pattern[j] {
                matches = false
                break
            }
            j += 1
        }
        if matches { return true }
        i += 1
    }

    return false
}

private func findStringValue(in object: Any, key: String) -> String? {
    if let dict = object as? [String: Any] {
        if let value = dict[key] as? String { return value }
        for value in dict.values {
            if let found = findStringValue(in: value, key: key) {
                return found
            }
        }
        return nil
    }

    if let arr = object as? [Any] {
        for value in arr {
            if let found = findStringValue(in: value, key: key) {
                return found
            }
        }
        return nil
    }

    return nil
}

private struct EvidenceStoreBackup {
    var settings: Data?
    var track1: Data?
    var track2: Data?
}

private struct LocaleSwitchingHarness: View {
    @ObservedObject var controller: AppLocaleController
    var bundle: Bundle

    var body: some View {
        LocalizedKeyText(key: "app.title", bundle: bundle)
            .environment(\.locale, controller.swiftUILocale)
    }
}

private struct LocalizedKeyText: View {
    var key: String
    var bundle: Bundle

    @Environment(\.locale) private var locale

    var body: some View {
        ProbeLabel(text: localizedString)
    }

    private var localizedString: String {
        if let languageCode = languageCode(from: locale.identifier),
           let path = bundle.path(forResource: languageCode, ofType: "lproj"),
           let localizedBundle = Bundle(path: path)
        {
            return NSLocalizedString(key, bundle: localizedBundle, value: key, comment: "")
        }
        return NSLocalizedString(key, bundle: bundle, value: key, comment: "")
    }
}

private struct ProbeLabel: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }
}

private func languageCode(from localeIdentifier: String) -> String? {
    let separators = CharacterSet(charactersIn: "-_")
    let parts = localeIdentifier.components(separatedBy: separators)
    guard let first = parts.first, first.isEmpty == false else { return nil }
    return first
}

private func localizedString(_ key: String, bundle: Bundle, languageCode: String) -> String {
    if let path = bundle.path(forResource: languageCode, ofType: "lproj"),
       let localizedBundle = Bundle(path: path)
    {
        return NSLocalizedString(key, bundle: localizedBundle, value: key, comment: "")
    }
    return NSLocalizedString(key, bundle: bundle, value: key, comment: "")
}

private func readIfExists(url: URL) -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? Data(contentsOf: url)
}

private func restoreFile(url: URL, backupData: Data?) {
    do {
        if let backupData {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try backupData.write(to: url, options: [.atomic])
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    } catch {
        NSLog("TokenMeterTests: restoreFile failed for %@: %@", url.path, String(describing: error))
    }
}

private func projectRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@MainActor
private func renderNativePNG<V: View>(
    view: V,
    size: CGSize,
    settleSeconds: TimeInterval
) throws -> Data {
    _ = NSApplication.shared

    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = true
    window.backgroundColor = NSColor.windowBackgroundColor
    window.hasShadow = false
    window.contentView = hosting
    window.orderFront(nil)

    settleMainRunLoop(for: settleSeconds)
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw NSError(domain: "TokenMeterTests.Evidence", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap rep"]) 
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)

    window.orderOut(nil)

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TokenMeterTests.Evidence", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"]) 
    }
    return data
}

@MainActor
private func settleMainRunLoop(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(max(0, seconds))
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

private func assertNonTrivialPNG(
    _ data: Data,
    minBytes: Int,
    minPixelsWide: Int,
    minPixelsHigh: Int
) throws {
    guard data.count >= minBytes else {
        throw NSError(
            domain: "TokenMeterTests.Evidence",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "PNG too small (\(data.count) bytes)"]
        )
    }

    guard
        let image = NSImage(data: data),
        let rep = image.representations.first as? NSBitmapImageRep
    else {
        throw NSError(domain: "TokenMeterTests.Evidence", code: 4, userInfo: [NSLocalizedDescriptionKey: "PNG did not decode"]) 
    }

    if rep.pixelsWide < minPixelsWide || rep.pixelsHigh < minPixelsHigh {
        throw NSError(
            domain: "TokenMeterTests.Evidence",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "PNG dimensions too small (\(rep.pixelsWide)x\(rep.pixelsHigh))"]
        )
    }
}

private final class ThreadSafeArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }
}

private func writeClaudeOAuthCredentialsJSON(
    homeDirectoryURL: URL,
    accessToken: String,
    expiresAtMs: Double
) throws {
    let dir = homeDirectoryURL.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let url = dir.appendingPathComponent(".credentials.json")
    let payload: [String: Any] = [
        "claudeAiOauth": [
            "accessToken": accessToken,
            "expiresAt": expiresAtMs,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(to: url, options: [.atomic])
}

private func appendText(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    if let data = text.data(using: .utf8) {
        try handle.write(contentsOf: data)
    }
}

private func writeOpenCodeMessage(
    homeDirectoryURL: URL,
    sessionID: String,
    messageID: String,
    payload: [String: Any]
) throws {
    let dir = homeDirectoryURL
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("share", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let dbURL = dir.appendingPathComponent("opencode.db")

    var message: [String: Any] = payload
    message["id"] = messageID
    message["sessionID"] = sessionID

    let epochMillis: Int64 = {
        func numeric(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }

        let time = message["time"] as? [String: Any]
        if let completed = numeric(time?["completed"]) {
            return Int64(completed.rounded())
        }
        if let created = numeric(time?["created"]) {
            return Int64(created.rounded())
        }
        return Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }()

    let jsonData = try JSONSerialization.data(withJSONObject: message)
    guard let jsonText = String(data: jsonData, encoding: .utf8) else {
        throw NSError(domain: "TokenMeterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode OpenCode message JSON"])
    }

    func escapeSQLString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    let sql = """
    CREATE TABLE IF NOT EXISTS message (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      time_created INTEGER NOT NULL,
      time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
    INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data)
    VALUES ('\(escapeSQLString(messageID))', '\(escapeSQLString(sessionID))', \(epochMillis), \(epochMillis), '\(escapeSQLString(jsonText))');
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [dbURL.path, sql]
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown sqlite3 error"
        throw NSError(domain: "TokenMeterTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
    }
}

private func appendLearningNote(root: URL) {
    let notepad = root
        .appendingPathComponent(".sisyphus", isDirectory: true)
        .appendingPathComponent("notepads", isDirectory: true)
        .appendingPathComponent("token-meter-macos-implementation", isDirectory: true)
        .appendingPathComponent("learnings.md")

    let line = "- UI evidence PNGs written by native XCTest (TOKEN_METER_WRITE_UI_EVIDENCE=1).\n"

    do {
        try FileManager.default.createDirectory(at: notepad.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: notepad.path) == false {
            try Data().write(to: notepad, options: [.atomic])
        }

        let handle = try FileHandle(forWritingTo: notepad)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    } catch {
        NSLog("TokenMeterTests: appendLearningNote failed: %@", String(describing: error))
    }
}

@MainActor
private func waitForText(_ expected: String, in root: NSView, timeoutSec: TimeInterval) -> String? {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
        root.layoutSubtreeIfNeeded()
        if let current = firstTextFieldString(in: root), current == expected {
            return current
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return firstTextFieldString(in: root)
}

@MainActor
private func firstTextFieldString(in view: NSView) -> String? {
    if let tf = view as? NSTextField {
        return tf.stringValue
    }
    for sub in view.subviews {
        if let found = firstTextFieldString(in: sub) {
            return found
        }
    }
    return nil
}
