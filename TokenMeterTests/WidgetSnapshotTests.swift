import Foundation
import XCTest

@testable import TokenMeter

final class WidgetSnapshotTests: XCTestCase {
    func testWidgetSnapshotStoreRoundTripPreservesTrackSeparation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = WidgetSnapshotStore(containerURLOverride: dir)
        let snapshot = WidgetSnapshot(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            track1: [
                WidgetSnapshot.Track1Summary(
                    provider: "codex",
                    observedAt: Date(timeIntervalSince1970: 1_700_000_123),
                    plan: "pro",
                    confidence: "high",
                    windows: [
                        WidgetSnapshot.Track1Summary.WindowSummary(
                            windowId: "weekly",
                            usedPercent: 25,
                            remainingPercent: 75,
                            resetAt: Date(timeIntervalSince1970: 1_700_000_500)
                        )
                    ]
                )
            ],
            track2: [
                WidgetSnapshot.Track2Summary(
                    provider: "codex",
                    lastTimestamp: Date(timeIntervalSince1970: 1_700_000_700),
                    lastModel: "gpt-5",
                    lastTotalTokens: 30,
                    pointsInLast24Hours: 2,
                    totalTokensInLast24Hours: 42,
                    series24h: [
                        WidgetSnapshot.Track2Summary.SeriesBar(
                            bucketStart: Date(timeIntervalSince1970: 1_700_000_000),
                            totalTokens: 42
                        )
                    ]
                )
            ]
        )

        try store.write(snapshot)
        let decoded = try store.read()
        XCTAssertEqual(decoded, snapshot)

        let snapshotURL = dir.appendingPathComponent(WidgetSharedConfig.snapshotFileName)
        let raw = try String(contentsOf: snapshotURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"track1\""))
        XCTAssertTrue(raw.contains("\"track2\""))
        XCTAssertTrue(raw.contains("\"series24h\""))
        XCTAssertTrue(raw.contains("\"stackedSeries24h\""))

        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let nowHourStart = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let prevHourStart = cal.date(byAdding: .hour, value: -1, to: nowHourStart) ?? nowHourStart.addingTimeInterval(-3600)

        let settings = AppSettings(
            codex: CodexSettings(enabled: true),
            claude: ClaudeSettings(enabled: false)
        )

        let p0 = Track2TimelinePoint(
            provider: .codex,
            timestamp: cal.date(byAdding: .minute, value: 10, to: prevHourStart) ?? prevHourStart,
            sessionId: "s1",
            model: "gpt-3.5-turbo",
            promptTokens: 10,
            completionTokens: 5,
            totalTokens: nil,
            sourceFile: "test.json",
            confidence: .high,
            parserVersion: "test"
        )

        let p1 = Track2TimelinePoint(
            provider: .codex,
            timestamp: cal.date(byAdding: .minute, value: 5, to: nowHourStart) ?? nowHourStart,
            sessionId: "s2",
            model: "gpt-5.2-codex",
            promptTokens: nil,
            completionTokens: nil,
            totalTokens: 25,
            sourceFile: "test.json",
            confidence: .high,
            parserVersion: "test"
        )

        // Build a new snapshot from timeline points. Rename to avoid shadowing the
        // earlier 'snapshot' variable used for round-trip store/read test.
        let builtSnapshot = WidgetSnapshotBuilder.make(
            settings: settings,
            track1Snapshots: [],
            track2Points: [p0, p1],
            now: now
        )

        let codex = builtSnapshot.track2.first(where: { $0.provider == "codex" })
        XCTAssertNotNil(codex)
        XCTAssertEqual(codex?.series24h.count, 96)
        XCTAssertEqual(codex?.stackedSeries24h.count, 96)

        // Derive per-hour totals directly from timeline points (p0 and p1)
        let bucketPrev = cal.dateInterval(of: .hour, for: p0.timestamp)?.start ?? prevHourStart
        let bucketNow = cal.dateInterval(of: .hour, for: p1.timestamp)?.start ?? nowHourStart
        var perBucket: [Date: Int] = [:]
        let p0Tokens = (p0.promptTokens ?? 0) + (p0.completionTokens ?? 0)
        perBucket[bucketPrev, default: 0] += p0Tokens
        perBucket[bucketNow, default: 0] += (p1.totalTokens ?? 0)

        XCTAssertEqual(perBucket[prevHourStart] ?? -1, 15)
        XCTAssertEqual(perBucket[nowHourStart] ?? -1, 25)

        let prevStacked = codex?.stackedSeries24h.first(where: { $0.bucketStart == prevHourStart })
        XCTAssertEqual(
            prevStacked?.segments,
            [
                WidgetSnapshot.Track2Summary.StackedSeriesBar.FamilySegment(
                    family: "GPT 3.5",
                    totalTokens: 15
                ),
            ]
        )

        let nowStacked = codex?.stackedSeries24h.first(where: { $0.bucketStart == nowHourStart })
        XCTAssertEqual(
            nowStacked?.segments,
            [
                WidgetSnapshot.Track2Summary.StackedSeriesBar.FamilySegment(
                    family: "GPT 5.2",
                    totalTokens: 25
                ),
            ]
        )
    }

    func testWidgetSnapshotBuilderUsesSelectedTrack2ScaleWithFixed96Buckets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AppSettings(
            codex: CodexSettings(enabled: true),
            claude: ClaudeSettings(enabled: false),
            widgetTrack2TimeScale: .hours3
        )

        let oldPoint = Track2TimelinePoint(
            provider: .codex,
            timestamp: now.addingTimeInterval(-(4 * 60 * 60)),
            sessionId: "old",
            model: "gpt-5",
            promptTokens: nil,
            completionTokens: nil,
            totalTokens: 100,
            sourceFile: "test.json",
            confidence: .high,
            parserVersion: "test"
        )

        let inWindowPromptCompletion = Track2TimelinePoint(
            provider: .codex,
            timestamp: now.addingTimeInterval(-(90 * 60)),
            sessionId: "in1",
            model: "gpt-5",
            promptTokens: 12,
            completionTokens: 8,
            totalTokens: nil,
            sourceFile: "test.json",
            confidence: .high,
            parserVersion: "test"
        )

        let inWindowTotal = Track2TimelinePoint(
            provider: .codex,
            timestamp: now.addingTimeInterval(-(10 * 60)),
            sessionId: "in2",
            model: "gpt-5",
            promptTokens: nil,
            completionTokens: nil,
            totalTokens: 30,
            sourceFile: "test.json",
            confidence: .high,
            parserVersion: "test"
        )

        let snapshot = WidgetSnapshotBuilder.make(
            settings: settings,
            track1Snapshots: [],
            track2Points: [oldPoint, inWindowPromptCompletion, inWindowTotal],
            now: now
        )

        let codex = snapshot.track2.first(where: { $0.provider == "codex" })
        XCTAssertNotNil(codex)
        XCTAssertEqual(codex?.series24h.count, 96)
        XCTAssertEqual(codex?.stackedSeries24h.count, 96)

        let bucketDelta = codex?.series24h[1].bucketStart.timeIntervalSince(codex?.series24h[0].bucketStart ?? now)
        XCTAssertEqual(Int(bucketDelta ?? 0), 113)

        let graphedTotal = codex?.series24h.map(\.totalTokens).reduce(0, +)
        XCTAssertEqual(graphedTotal, 50)
        XCTAssertEqual(codex?.totalTokensInLast24Hours, 150)
    }

    func testTrack2ModelClassifierMapsCodexAndClaudeFamilies() {
        XCTAssertEqual(
            Track2ModelClassifier.familyLabel(provider: .codex, model: "gpt-3.5-turbo"),
            "GPT 3.5"
        )
        XCTAssertEqual(
            Track2ModelClassifier.familyLabel(provider: .codex, model: "gpt-5.2-codex"),
            "GPT 5.2"
        )
        XCTAssertEqual(
            Track2ModelClassifier.familyLabel(provider: .claude, model: "claude-opus-4-6-20260101"),
            "Opus 4.6"
        )
        XCTAssertEqual(
            Track2ModelClassifier.familyLabel(provider: .claude, model: "claude-sonnet-4-5"),
            "Sonnet 4.5"
        )
        XCTAssertEqual(
            Track2ModelClassifier.familyLabel(provider: .claude, model: nil),
            "Unknown"
        )
    }

    func testTrack2SummaryDecodesWithoutStackedSeriesField() throws {
        let json = """
        {
          "provider": "codex",
          "lastTimestamp": "2025-11-25T10:00:00Z",
          "lastModel": "gpt-5",
          "lastTotalTokens": 42,
          "pointsInLast24Hours": 3,
          "totalTokensInLast24Hours": 123,
          "series24h": [
            {
              "bucketStart": "2025-11-25T09:00:00Z",
              "totalTokens": 12
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(WidgetSnapshot.Track2Summary.self, from: Data(json.utf8))

        XCTAssertEqual(summary.provider, "codex")
        XCTAssertEqual(summary.series24h.count, 1)
        XCTAssertEqual(summary.stackedSeries24h, [])
    }
}
