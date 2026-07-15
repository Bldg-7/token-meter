import Foundation

struct WidgetSnapshot: Codable, Equatable {
    var schemaVersion: Int
    var generatedAt: Date
    var track1: [Track1Summary]
    var track2: [Track2Summary]

    struct Track1Summary: Codable, Equatable {
        var provider: String
        var observedAt: Date?
        var plan: String
        var confidence: String
        var windows: [WindowSummary]

        struct WindowSummary: Codable, Equatable {
            var windowId: String
            var usedPercent: Double?
            var remainingPercent: Double?
            var resetAt: Date?
        }
    }

    struct Track2Summary: Codable, Equatable {
        var provider: String
        var lastTimestamp: Date?
        var lastModel: String?
        var lastTotalTokens: Int?
        var pointsInLast24Hours: Int
        var totalTokensInLast24Hours: Int
        var series24h: [SeriesBar]
        var stackedSeries24h: [StackedSeriesBar]
        var quotaOverlay5h: [QuotaOverlayBar]

        struct SeriesBar: Codable, Equatable {
            var bucketStart: Date
            var totalTokens: Int
        }

        struct StackedSeriesBar: Codable, Equatable {
            var bucketStart: Date
            var segments: [FamilySegment]

            struct FamilySegment: Codable, Equatable {
                var family: String
                var totalTokens: Int
            }
        }

        struct QuotaOverlayBar: Codable, Equatable {
            var bucketStart: Date
            var usedPercent: Double?
            var isReset: Bool
            var isGap: Bool
        }

        init(
            provider: String,
            lastTimestamp: Date?,
            lastModel: String?,
            lastTotalTokens: Int?,
            pointsInLast24Hours: Int,
            totalTokensInLast24Hours: Int,
            series24h: [SeriesBar],
            stackedSeries24h: [StackedSeriesBar] = [],
            quotaOverlay5h: [QuotaOverlayBar] = []
        ) {
            self.provider = provider
            self.lastTimestamp = lastTimestamp
            self.lastModel = lastModel
            self.lastTotalTokens = lastTotalTokens
            self.pointsInLast24Hours = pointsInLast24Hours
            self.totalTokensInLast24Hours = totalTokensInLast24Hours
            self.series24h = series24h
            self.stackedSeries24h = stackedSeries24h
            self.quotaOverlay5h = quotaOverlay5h
        }

        init(
            provider: String,
            lastTimestamp: Date?,
            lastModel: String?,
            lastTotalTokens: Int?,
            pointsInLast24Hours: Int,
            totalTokensInLast24Hours: Int
        ) {
            self.init(
                provider: provider,
                lastTimestamp: lastTimestamp,
                lastModel: lastModel,
                lastTotalTokens: lastTotalTokens,
                pointsInLast24Hours: pointsInLast24Hours,
                totalTokensInLast24Hours: totalTokensInLast24Hours,
                series24h: [],
                stackedSeries24h: [],
                quotaOverlay5h: []
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decode(String.self, forKey: .provider)
            lastTimestamp = try container.decodeIfPresent(Date.self, forKey: .lastTimestamp)
            lastModel = try container.decodeIfPresent(String.self, forKey: .lastModel)
            lastTotalTokens = try container.decodeIfPresent(Int.self, forKey: .lastTotalTokens)
            pointsInLast24Hours = try container.decode(Int.self, forKey: .pointsInLast24Hours)
            totalTokensInLast24Hours = try container.decode(Int.self, forKey: .totalTokensInLast24Hours)
            series24h = try container.decodeIfPresent([SeriesBar].self, forKey: .series24h) ?? []
            stackedSeries24h = try container.decodeIfPresent([StackedSeriesBar].self, forKey: .stackedSeries24h) ?? []
            quotaOverlay5h = try container.decodeIfPresent([QuotaOverlayBar].self, forKey: .quotaOverlay5h) ?? []
        }
    }
}

extension WidgetSnapshot.Track1Summary {
    /// Preference order for surfaces that show a single quota window. Codex
    /// stopped reporting a rolling 5h window in July 2026 (weekly-only
    /// limits), so weekly is the fallback.
    static let quotaWindowPreference = ["rolling_5h", "weekly"]

    /// Quota window for compact widget families: the highest-preference
    /// window carrying usable percent data. Degraded snapshots can list a
    /// window with all-nil fields, which must not shadow a populated
    /// lower-preference window; a percent-less window is only returned when
    /// no preferred window has data (it may still offer a reset countdown).
    var primaryQuotaWindow: WindowSummary? {
        for windowId in Self.quotaWindowPreference {
            if let window = windows.first(where: {
                $0.windowId == windowId && ($0.usedPercent != nil || $0.remainingPercent != nil)
            }) {
                return window
            }
        }
        for windowId in Self.quotaWindowPreference {
            if let window = windows.first(where: { $0.windowId == windowId }) {
                return window
            }
        }
        return nil
    }
}
