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

        init(
            provider: String,
            lastTimestamp: Date?,
            lastModel: String?,
            lastTotalTokens: Int?,
            pointsInLast24Hours: Int,
            totalTokensInLast24Hours: Int,
            series24h: [SeriesBar],
            stackedSeries24h: [StackedSeriesBar] = []
        ) {
            self.provider = provider
            self.lastTimestamp = lastTimestamp
            self.lastModel = lastModel
            self.lastTotalTokens = lastTotalTokens
            self.pointsInLast24Hours = pointsInLast24Hours
            self.totalTokensInLast24Hours = totalTokensInLast24Hours
            self.series24h = series24h
            self.stackedSeries24h = stackedSeries24h
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
                stackedSeries24h: []
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
        }
    }
}
