import Foundation

enum WidgetSnapshotBuilder {
    private static let graphBucketCount = 96

    static func make(
        settings: AppSettings,
        track1Snapshots: [Track1Snapshot],
        track2Points: [Track2TimelinePoint],
        now: Date = Date()
    ) -> WidgetSnapshot {
        let providers = enabledProviders(settings: settings)
        let latestTrack1 = latestTrack1ByProvider(track1Snapshots)
        let track2ByProvider = Dictionary(grouping: track2Points, by: \.provider)

        let track1 = providers.map { provider -> WidgetSnapshot.Track1Summary in
            guard let snapshot = latestTrack1[provider] else {
                return WidgetSnapshot.Track1Summary(
                    provider: provider.rawValue,
                    observedAt: nil,
                    plan: "unknown",
                    confidence: "missing",
                    windows: []
                )
            }

            let windows = snapshot.windows.map { window in
                WidgetSnapshot.Track1Summary.WindowSummary(
                    windowId: window.windowId.rawValue,
                    usedPercent: window.usedPercent,
                    remainingPercent: window.remainingPercent,
                    resetAt: window.resetAt
                )
            }

            return WidgetSnapshot.Track1Summary(
                provider: provider.rawValue,
                observedAt: snapshot.observedAt,
                plan: snapshot.plan.rawValue,
                confidence: snapshot.confidence.rawValue,
                windows: windows
            )
        }

        let last24hStart = now.addingTimeInterval(-(24 * 60 * 60))
        let graphScale = settings.widgetTrack2TimeScale
        let graphBucketSeconds = bucketSeconds(for: graphScale, bucketCount: graphBucketCount)

        let track2 = providers.map { provider -> WidgetSnapshot.Track2Summary in
            let points = (track2ByProvider[provider] ?? []).sorted { $0.timestamp < $1.timestamp }
            let recent24h = points.filter { $0.timestamp >= last24hStart && $0.timestamp <= now }
            let last = points.last

            let series24h = track2Series(
                points: points,
                now: now,
                bucketCount: graphBucketCount,
                bucketSeconds: graphBucketSeconds
            )
            let stackedSeries24h = track2StackedSeries(
                points: points,
                now: now,
                bucketCount: graphBucketCount,
                bucketSeconds: graphBucketSeconds
            )

            return WidgetSnapshot.Track2Summary(
                provider: provider.rawValue,
                lastTimestamp: last?.timestamp,
                lastModel: normalizedModel(last?.model),
                lastTotalTokens: last.flatMap(totalTokens(for:)),
                pointsInLast24Hours: recent24h.count,
                totalTokensInLast24Hours: recent24h.compactMap(totalTokens(for:)).reduce(0, +),
                series24h: series24h,
                stackedSeries24h: stackedSeries24h
            )
        }

        return WidgetSnapshot(
            schemaVersion: 1,
            generatedAt: now,
            track1: track1,
            track2: track2
        )
    }

    private static func enabledProviders(settings: AppSettings) -> [ProviderId] {
        var providers: [ProviderId] = []
        if settings.codex.enabled {
            providers.append(.codex)
        }
        if settings.claude.enabled {
            providers.append(.claude)
        }
        return providers
    }

    private static func latestTrack1ByProvider(_ snapshots: [Track1Snapshot]) -> [ProviderId: Track1Snapshot] {
        var out: [ProviderId: Track1Snapshot] = [:]
        for snapshot in snapshots {
            if let existing = out[snapshot.provider] {
                if snapshot.observedAt > existing.observedAt {
                    out[snapshot.provider] = snapshot
                }
            } else {
                out[snapshot.provider] = snapshot
            }
        }
        return out
    }

    private static func totalTokens(for point: Track2TimelinePoint) -> Int? {
        if let total = point.totalTokens {
            return total
        }
        if let prompt = point.promptTokens, let completion = point.completionTokens {
            return prompt + completion
        }
        return nil
    }

    private static func track2Series(
        points: [Track2TimelinePoint],
        now: Date,
        bucketCount: Int,
        bucketSeconds: Int
    ) -> [WidgetSnapshot.Track2Summary.SeriesBar] {
        guard bucketCount > 0, bucketSeconds > 0 else { return [] }

        let endBucketStart = floorToBucketBoundary(now, bucketSeconds: bucketSeconds)
        let firstBucketStart = endBucketStart.addingTimeInterval(TimeInterval(-bucketSeconds * (bucketCount - 1)))
        let endExclusive = endBucketStart.addingTimeInterval(TimeInterval(bucketSeconds))

        var grouped: [Date: Int] = [:]
        for point in points {
            guard point.timestamp >= firstBucketStart,
                  point.timestamp < endExclusive,
                  point.timestamp <= now,
                  let total = totalTokens(for: point)
            else {
                continue
            }
            let bucketStart = floorToBucketBoundary(point.timestamp, bucketSeconds: bucketSeconds)
            grouped[bucketStart, default: 0] += total
        }

        var out: [WidgetSnapshot.Track2Summary.SeriesBar] = []
        out.reserveCapacity(bucketCount)

        for offset in 0..<bucketCount {
            let bucketStart = firstBucketStart.addingTimeInterval(TimeInterval(offset * bucketSeconds))
            let total = grouped[bucketStart, default: 0]
            out.append(WidgetSnapshot.Track2Summary.SeriesBar(bucketStart: bucketStart, totalTokens: total))
        }

        return out
    }

    private static func track2StackedSeries(
        points: [Track2TimelinePoint],
        now: Date,
        bucketCount: Int,
        bucketSeconds: Int
    ) -> [WidgetSnapshot.Track2Summary.StackedSeriesBar] {
        guard bucketCount > 0, bucketSeconds > 0 else { return [] }

        let endBucketStart = floorToBucketBoundary(now, bucketSeconds: bucketSeconds)
        let firstBucketStart = endBucketStart.addingTimeInterval(TimeInterval(-bucketSeconds * (bucketCount - 1)))
        let endExclusive = endBucketStart.addingTimeInterval(TimeInterval(bucketSeconds))

        var grouped: [Date: [Track2TimelinePoint]] = [:]
        for point in points {
            guard point.timestamp >= firstBucketStart,
                  point.timestamp < endExclusive,
                  point.timestamp <= now
            else {
                continue
            }

            let bucketStart = floorToBucketBoundary(point.timestamp, bucketSeconds: bucketSeconds)
            grouped[bucketStart, default: []].append(point)
        }

        var out: [WidgetSnapshot.Track2Summary.StackedSeriesBar] = []
        out.reserveCapacity(bucketCount)

        for offset in 0..<bucketCount {
            let bucketStart = firstBucketStart.addingTimeInterval(TimeInterval(offset * bucketSeconds))
            let bucketPoints = grouped[bucketStart] ?? []

            var familyTotals: [String: Int] = [:]
            for point in bucketPoints {
                guard let total = totalTokens(for: point), total > 0 else { continue }
                let family = Track2ModelClassifier.familyLabel(provider: point.provider, model: point.model)
                familyTotals[family, default: 0] += total
            }

            let segments = familyTotals
                .map { family, total in
                    WidgetSnapshot.Track2Summary.StackedSeriesBar.FamilySegment(family: family, totalTokens: total)
                }
                .sorted {
                    if $0.totalTokens != $1.totalTokens {
                        return $0.totalTokens > $1.totalTokens
                    }
                    return $0.family < $1.family
                }

            out.append(
                WidgetSnapshot.Track2Summary.StackedSeriesBar(
                    bucketStart: bucketStart,
                    segments: segments
                )
            )
        }

        return out
    }

    private static func bucketSeconds(for scale: Track2WidgetTimeScale, bucketCount: Int) -> Int {
        guard bucketCount > 0 else { return 0 }
        return max(1, Int((scale.windowSeconds / Double(bucketCount)).rounded()))
    }

    private static func floorToBucketBoundary(_ date: Date, bucketSeconds: Int) -> Date {
        guard bucketSeconds > 0 else { return date }
        let epoch = Int(date.timeIntervalSince1970)
        let snapped = (epoch / bucketSeconds) * bucketSeconds
        return Date(timeIntervalSince1970: TimeInterval(snapped))
    }

    private static func normalizedModel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
