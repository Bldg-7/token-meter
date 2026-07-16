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
        XCTAssertEqual(codex?.quotaOverlay5h.count, 96)

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
        XCTAssertEqual(codex?.quotaOverlay5h.count, 96)

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
            Track2ModelClassifier.familyLabel(provider: .codex, model: "gpt-5.6-sol"),
            "GPT 5.6 Sol"
        )
        XCTAssertEqual(
            Track2ModelClassifier.familyLabel(provider: .codex, model: "openai/gpt-5.6-terra"),
            "GPT 5.6 Terra"
        )
        XCTAssertEqual(
            Track2ModelClassifier.familyLabel(provider: .codex, model: "gpt-5.6-luna"),
            "GPT 5.6 Luna"
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
        XCTAssertEqual(summary.quotaOverlay5h, [])
    }

    func testQuotaOverlaySeriesMarksResetAndCollectionGap() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AppSettings(
            codex: CodexSettings(enabled: true),
            claude: ClaudeSettings(enabled: false),
            widgetTrack2TimeScale: .hours3
        )

        let snapshots: [Track1Snapshot] = [
            Track1Snapshot(
                provider: .codex,
                observedAt: now.addingTimeInterval(-160 * 60),
                source: .cliMethodB,
                plan: .pro,
                windows: [
                    Track1Window(
                        windowId: .rolling5h,
                        usedPercent: 62,
                        remainingPercent: 38,
                        resetAt: now.addingTimeInterval(-70 * 60),
                        rawScopeLabel: "rolling_5h"
                    ),
                ],
                confidence: .high,
                parserVersion: "test"
            ),
            Track1Snapshot(
                provider: .codex,
                observedAt: now.addingTimeInterval(-145 * 60),
                source: .cliMethodB,
                plan: .pro,
                windows: [
                    Track1Window(
                        windowId: .rolling5h,
                        usedPercent: 74,
                        remainingPercent: 26,
                        resetAt: now.addingTimeInterval(-70 * 60),
                        rawScopeLabel: "rolling_5h"
                    ),
                ],
                confidence: .high,
                parserVersion: "test"
            ),
            Track1Snapshot(
                provider: .codex,
                observedAt: now.addingTimeInterval(-35 * 60),
                source: .cliMethodB,
                plan: .pro,
                windows: [
                    Track1Window(
                        windowId: .rolling5h,
                        usedPercent: 4,
                        remainingPercent: 96,
                        resetAt: now.addingTimeInterval(4 * 60 * 60),
                        rawScopeLabel: "rolling_5h"
                    ),
                ],
                confidence: .high,
                parserVersion: "test"
            ),
        ]

        let snapshot = WidgetSnapshotBuilder.make(
            settings: settings,
            track1Snapshots: snapshots,
            track2Points: [],
            now: now
        )

        let codex = snapshot.track2.first(where: { $0.provider == "codex" })
        XCTAssertNotNil(codex)
        XCTAssertEqual(codex?.quotaOverlay5h.count, 96)
        XCTAssertTrue(codex?.quotaOverlay5h.contains(where: \.isReset) == true)
        XCTAssertTrue(codex?.quotaOverlay5h.contains(where: \.isGap) == true)
    }

    func testQuotaOverlayFallsBackToWeeklyWindowWhenLatestSnapshotHasNoRolling5h() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AppSettings(
            codex: CodexSettings(enabled: true),
            claude: ClaudeSettings(enabled: false),
            widgetTrack2TimeScale: .hours3
        )

        let snapshots: [Track1Snapshot] = [
            // Pre-transition snapshot still reporting both windows.
            Track1Snapshot(
                provider: .codex,
                observedAt: now.addingTimeInterval(-100 * 60),
                source: .cliMethodB,
                plan: .pro,
                windows: [
                    Track1Window(
                        windowId: .rolling5h,
                        usedPercent: 40,
                        remainingPercent: 60,
                        resetAt: now.addingTimeInterval(2 * 60 * 60),
                        rawScopeLabel: "rolling_5h"
                    ),
                    Track1Window(
                        windowId: .weekly,
                        usedPercent: 31,
                        remainingPercent: 69,
                        resetAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                        rawScopeLabel: "weekly"
                    ),
                ],
                confidence: .high,
                parserVersion: "test"
            ),
            // Weekly-only snapshot after Codex dropped the 5h limit.
            Track1Snapshot(
                provider: .codex,
                observedAt: now.addingTimeInterval(-30 * 60),
                source: .cliMethodB,
                plan: .pro,
                windows: [
                    Track1Window(
                        windowId: .weekly,
                        usedPercent: 33,
                        remainingPercent: 67,
                        resetAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                        rawScopeLabel: "weekly"
                    ),
                ],
                confidence: .high,
                parserVersion: "test"
            ),
        ]

        let snapshot = WidgetSnapshotBuilder.make(
            settings: settings,
            track1Snapshots: snapshots,
            track2Points: [],
            now: now
        )

        let codex = snapshot.track2.first(where: { $0.provider == "codex" })
        XCTAssertNotNil(codex)
        XCTAssertEqual(codex?.quotaOverlay5h.count, 96)

        let observedPercents = codex?.quotaOverlay5h.compactMap(\.usedPercent) ?? []
        XCTAssertTrue(observedPercents.contains(31))
        XCTAssertTrue(observedPercents.contains(33))
        XCTAssertFalse(observedPercents.contains(40))
    }

    func testQuotaOverlayIgnoresDegradedLatestSnapshotWithoutUsablePercent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AppSettings(
            codex: CodexSettings(enabled: true),
            claude: ClaudeSettings(enabled: false),
            widgetTrack2TimeScale: .hours3
        )

        let healthy = Track1Snapshot(
            provider: .codex,
            observedAt: now.addingTimeInterval(-40 * 60),
            source: .cliMethodB,
            plan: .pro,
            windows: [
                Track1Window(
                    windowId: .rolling5h,
                    usedPercent: 55,
                    remainingPercent: 45,
                    resetAt: now.addingTimeInterval(2 * 60 * 60),
                    rawScopeLabel: "rolling_5h"
                ),
            ],
            confidence: .high,
            parserVersion: "test"
        )

        // Plan-only fallback snapshot: a bare weekly window with no percent.
        let degradedLatest = Track1Snapshot(
            provider: .codex,
            observedAt: now.addingTimeInterval(-5 * 60),
            source: .cliMethodB,
            plan: .pro,
            windows: [
                Track1Window(
                    windowId: .weekly,
                    usedPercent: nil,
                    remainingPercent: nil,
                    resetAt: nil,
                    rawScopeLabel: "weekly"
                ),
            ],
            confidence: .medium,
            parserVersion: "test"
        )

        let snapshot = WidgetSnapshotBuilder.make(
            settings: settings,
            track1Snapshots: [healthy, degradedLatest],
            track2Points: [],
            now: now
        )

        let codex = snapshot.track2.first(where: { $0.provider == "codex" })
        let observedPercents = codex?.quotaOverlay5h.compactMap(\.usedPercent) ?? []
        XCTAssertTrue(observedPercents.contains(55))
    }

    func testTrack1SummaryPrimaryQuotaWindowPrefersRolling5hThenWeekly() {
        let rolling = WidgetSnapshot.Track1Summary.WindowSummary(
            windowId: "rolling_5h",
            usedPercent: 10,
            remainingPercent: 90,
            resetAt: nil
        )
        let weekly = WidgetSnapshot.Track1Summary.WindowSummary(
            windowId: "weekly",
            usedPercent: 20,
            remainingPercent: 80,
            resetAt: nil
        )
        let session = WidgetSnapshot.Track1Summary.WindowSummary(
            windowId: "session",
            usedPercent: 5,
            remainingPercent: 95,
            resetAt: nil
        )

        func summary(_ windows: [WidgetSnapshot.Track1Summary.WindowSummary]) -> WidgetSnapshot.Track1Summary {
            WidgetSnapshot.Track1Summary(
                provider: "codex",
                observedAt: nil,
                plan: "pro",
                confidence: "high",
                windows: windows
            )
        }

        XCTAssertEqual(summary([weekly, rolling]).primaryQuotaWindow?.windowId, "rolling_5h")
        XCTAssertEqual(summary([session, weekly]).primaryQuotaWindow?.windowId, "weekly")
        XCTAssertNil(summary([session]).primaryQuotaWindow)

        // A degraded rolling_5h stub with no percents must not shadow a
        // populated weekly window, but is still returned when nothing better
        // exists.
        let emptyRolling = WidgetSnapshot.Track1Summary.WindowSummary(
            windowId: "rolling_5h",
            usedPercent: nil,
            remainingPercent: nil,
            resetAt: nil
        )
        XCTAssertEqual(summary([emptyRolling, weekly]).primaryQuotaWindow?.windowId, "weekly")
        XCTAssertEqual(summary([emptyRolling]).primaryQuotaWindow?.windowId, "rolling_5h")
    }

    func testWidgetSnapshotBuilderPassesThroughResetCreditsAvailable() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AppSettings(
            codex: CodexSettings(enabled: true),
            claude: ClaudeSettings(enabled: false)
        )

        let track1 = Track1Snapshot(
            provider: .codex,
            observedAt: now.addingTimeInterval(-60),
            source: .cliMethodB,
            plan: .pro,
            windows: [
                Track1Window(
                    windowId: .weekly,
                    usedPercent: 20,
                    remainingPercent: 80,
                    resetAt: nil,
                    rawScopeLabel: "weekly"
                ),
            ],
            confidence: .high,
            parserVersion: "test",
            resetCreditsAvailable: 2
        )

        let snapshot = WidgetSnapshotBuilder.make(
            settings: settings,
            track1Snapshots: [track1],
            track2Points: [],
            now: now
        )

        XCTAssertEqual(snapshot.track1.first?.resetCreditsAvailable, 2)

        // Older persisted summaries without the field must keep decoding.
        let legacyJSON = """
        {
          "provider": "codex",
          "plan": "pro",
          "confidence": "high",
          "windows": []
        }
        """
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(WidgetSnapshot.Track1Summary.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.resetCreditsAvailable)
    }
}
