import Foundation
import SwiftUI
import WidgetKit

struct TokenMeterWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
}

private enum WidgetProvider: String {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }
}

fileprivate let track2FamilyPalette: [Color] = [
    Color(red: 0.31, green: 0.56, blue: 0.96),
    Color(red: 0.30, green: 0.74, blue: 0.45),
    Color(red: 0.95, green: 0.63, blue: 0.25),
    Color(red: 0.89, green: 0.44, blue: 0.77),
    Color(red: 0.44, green: 0.74, blue: 0.87),
    Color(red: 0.91, green: 0.42, blue: 0.42),
]

struct TokenMeterWidgetProvider: TimelineProvider {
    private let snapshotStore = WidgetSnapshotStore()

    func placeholder(in context: Context) -> TokenMeterWidgetEntry {
        TokenMeterWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TokenMeterWidgetEntry) -> Void) {
        completion(TokenMeterWidgetEntry(date: Date(), snapshot: try? snapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TokenMeterWidgetEntry>) -> Void) {
        let now = Date()
        let entry = TokenMeterWidgetEntry(date: now, snapshot: try? snapshotStore.read())
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

private struct TokenMeterProviderWidgetView: View {
    var entry: TokenMeterWidgetProvider.Entry
    var provider: WidgetProvider

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            providerSnapshotView(snapshot: snapshot)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            emptySnapshotView
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func providerSnapshotView(snapshot: WidgetSnapshot) -> some View {
        let track1 = snapshot.track1.first(where: { $0.provider == provider.rawValue })
        let track2 = snapshot.track2.first(where: { $0.provider == provider.rawValue })

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.displayName)
                    .font(.headline)

                Spacer(minLength: 8)

                if let plan = track1?.plan, plan.isEmpty == false {
                    Text(displayPlan(plan))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("widget.unknown")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if family == .systemSmall {
                smallQuotaSummary(track1: track1)
            } else if family == .systemMedium {
                mediumQuotaSummary(track1: track1)
                track2Graphic(track2: track2)
            } else {
                track1QuotaRows(track1: track1)
                Spacer(minLength: 0)
                largeWindowUsage(track2: track2)
                track2Graphic(track2: track2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func displayPlan(_ rawPlan: String) -> String {
        let trimmed = rawPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return localizedString("widget.unknown")
        }

        let first = trimmed.prefix(1).uppercased()
        let rest = trimmed.dropFirst()
        return first + rest
    }

    @ViewBuilder
    private func smallQuotaSummary(track1: WidgetSnapshot.Track1Summary?) -> some View {
        if let window = primaryQuotaWindow(track1: track1) {
            let remainingLabel = resetRemainingLabel(resetAt: window.resetAt)
            let used = effectiveUsedPercent(for: window)

            VStack(spacing: 0) {
                Spacer(minLength: 10)
                QuotaRing(
                    usedPercent: used,
                    centerLabel: remainingLabel
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 3)
        } else {
            Text("widget.quota_na")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func mediumQuotaSummary(track1: WidgetSnapshot.Track1Summary?) -> some View {
        if let rolling = primaryQuotaWindow(track1: track1) {
            let used = effectiveUsedPercent(for: rolling)
            let remainingLabel = resetRemainingLabel(resetAt: rolling.resetAt)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("widget.quota_5h")
                        .font(.caption2.weight(.semibold))

                    Spacer(minLength: 8)

                    if let used {
                        Text("\(Int(used.rounded()))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("widget.na")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    Text("widget.reset_in")
                    Text(remainingLabel)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        } else {
            Text("widget.quota_5h_na")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func primaryQuotaWindow(track1: WidgetSnapshot.Track1Summary?) -> WidgetSnapshot.Track1Summary.WindowSummary? {
        guard let windows = track1?.windows else {
            return nil
        }

        return windowSummary(id: "rolling_5h", in: windows)
    }

    private func resetRemainingLabel(resetAt: Date?) -> String {
        guard let resetAt else {
            return "--"
        }

        let totalSeconds = max(0, Int(resetAt.timeIntervalSinceNow.rounded()))
        if totalSeconds == 0 {
            return localizedString("widget.now")
        }

        let minutes = totalSeconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remMinutes = minutes % 60
        if hours < 24 {
            return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
        }

        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    }

    @ViewBuilder
    private func track1QuotaRows(track1: WidgetSnapshot.Track1Summary?) -> some View {
        let rows = quotaWindows(for: track1)

        if rows.isEmpty {
            Text("widget.quota_na")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.caption2.weight(.semibold))

                            Spacer(minLength: 8)

                            if let used = effectiveUsedPercent(for: row.window) {
                                Text("\(Int(used.rounded()))%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("widget.na")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let used = effectiveUsedPercent(for: row.window) {
                            ProgressView(value: used / 100.0)
                                .controlSize(.small)
                        }

                        if let resetAt = row.window.resetAt {
                            HStack(spacing: 4) {
                                Text("widget.resets")
                                Text(resetAt, style: .relative)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func quotaWindows(for track1: WidgetSnapshot.Track1Summary?) -> [Track1QuotaRow] {
        guard let windows = track1?.windows else {
            return []
        }

        let rolling = windowSummary(id: "rolling_5h", in: windows)
        let weekly = windowSummary(id: "weekly", in: windows)

        if family == .systemLarge {
            var rows: [Track1QuotaRow] = []
            if let rolling {
                rows.append(Track1QuotaRow(title: quotaDisplayTitle(for: "rolling_5h"), window: rolling))
            }
            if let weekly {
                rows.append(Track1QuotaRow(title: quotaDisplayTitle(for: "weekly"), window: weekly))
            }
            if rows.isEmpty, let fallback = fallbackWindow(in: windows) {
                rows.append(Track1QuotaRow(title: quotaDisplayTitle(for: fallback.windowId), window: fallback))
            }
            return rows
        }

        if let rolling {
            return [Track1QuotaRow(title: quotaDisplayTitle(for: "rolling_5h"), window: rolling)]
        }
        return []
    }

    private func windowSummary(
        id: String,
        in windows: [WidgetSnapshot.Track1Summary.WindowSummary]
    ) -> WidgetSnapshot.Track1Summary.WindowSummary? {
        windows.first(where: { $0.windowId == id })
    }

    private func fallbackWindow(
        in windows: [WidgetSnapshot.Track1Summary.WindowSummary]
    ) -> WidgetSnapshot.Track1Summary.WindowSummary? {
        windows.first {
            $0.windowId != "rolling_5h"
                && $0.windowId != "weekly"
                && $0.windowId != "model_specific"
                && $0.usedPercent != nil
        }
    }

    private func effectiveUsedPercent(for window: WidgetSnapshot.Track1Summary.WindowSummary) -> Double? {
        if let used = window.usedPercent {
            return clampPercent(used)
        }
        if let remaining = window.remainingPercent {
            return clampPercent(100.0 - remaining)
        }
        return nil
    }

    private func clampPercent(_ value: Double) -> Double {
        min(100.0, max(0.0, value))
    }

    private func quotaDisplayTitle(for windowId: String) -> String {
        switch windowId {
        case "rolling_5h":
            return localizedString("widget.quota_5h")
        case "weekly":
            return localizedString("widget.quota_week")
        default:
            return windowId
        }
    }

    private struct Track1QuotaRow: Identifiable {
        let title: String
        let window: WidgetSnapshot.Track1Summary.WindowSummary

        var id: String { title }
    }

    private struct QuotaRing: View {
        var usedPercent: Double?
        var centerLabel: String

        private var usedFraction: CGFloat {
            guard let usedPercent else { return 0 }
            return CGFloat(min(100, max(0, usedPercent)) / 100.0)
        }

        var body: some View {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.18), lineWidth: 9)

                Circle()
                    .trim(from: 0, to: usedFraction)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Text(centerLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 50)
            }
            .frame(width: 74, height: 74)
        }
    }

    @ViewBuilder
    private func largeWindowUsage(track2: WidgetSnapshot.Track2Summary?) -> some View {
        let bars = stackedSeriesBars(track2: track2)
        let usage = bars.reduce(0) { partial, bar in
            partial + bar.segments.map(\.totalTokens).reduce(0, +)
        }

        if bars.isEmpty {
            Text("widget.usage_na")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            let window = timeWindowLabel(from: bars)
            HStack(spacing: 6) {
                Text(String(format: localizedString("widget.usage_window_format"), window))
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(formatTokenCount(usage))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func track2Graphic(track2: WidgetSnapshot.Track2Summary?) -> some View {
        let bars = stackedSeriesBars(track2: track2)
        let bucketSeconds = inferredBucketSeconds(from: bars)

        if bars.isEmpty {
            Text("widget.no_local_telemetry")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                DotStackedBarGraph(
                    bars: bars,
                    maxDots: dotRowCount
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: dotGraphHeight)
                MiniBarAxisLabels(
                    bars: axisBars(from: bars),
                    bucketSeconds: bucketSeconds
                )
                    .frame(maxWidth: .infinity, alignment: .leading)

                if family == .systemLarge {
                    largeTrack2Legend(bars: bars)
                }
            }
        }
    }

    @ViewBuilder
    private func largeTrack2Legend(bars: [WidgetSnapshot.Track2Summary.StackedSeriesBar]) -> some View {
        let families = legendFamilies(from: bars)
        if families.isEmpty == false {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 82), spacing: 8)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(Array(families.enumerated()), id: \.element) { index, family in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(track2FamilyPalette[index % track2FamilyPalette.count].opacity(0.9))
                            .frame(width: 6, height: 6)

                        Text(family)
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            }
        }
    }

    private func legendFamilies(from bars: [WidgetSnapshot.Track2Summary.StackedSeriesBar]) -> [String] {
        var totals: [String: Int] = [:]
        for bar in bars {
            for segment in bar.segments where segment.totalTokens > 0 {
                totals[segment.family, default: 0] += segment.totalTokens
            }
        }

        return totals
            .sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return $0.key < $1.key
            }
            .map(\.key)
    }

    private func timeWindowLabel(from bars: [WidgetSnapshot.Track2Summary.StackedSeriesBar]) -> String {
        let bucket = inferredBucketSeconds(from: bars)
        let seconds = max(0, bucket * max(1, bars.count))
        let candidates: [(Int, String)] = [
            (24 * 60 * 60, "24h"),
            (12 * 60 * 60, "12h"),
            (6 * 60 * 60, "6h"),
            (3 * 60 * 60, "3h"),
            (1 * 60 * 60, "1h"),
        ]

        if let nearest = candidates.min(by: { abs($0.0 - seconds) < abs($1.0 - seconds) }) {
            return nearest.1
        }

        let minutes = seconds / 60
        if minutes >= 60 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private func formatTokenCount(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        let sign = value < 0 ? "-" : ""

        if magnitude >= 1_000_000_000 {
            return "\(sign)\(formattedCompactTokenValue(magnitude / 1_000_000_000))B"
        }
        if magnitude >= 1_000_000 {
            return "\(sign)\(formattedCompactTokenValue(magnitude / 1_000_000))M"
        }
        if magnitude >= 1_000 {
            return "\(sign)\(formattedCompactTokenValue(magnitude / 1_000))K"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formattedCompactTokenValue(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = value >= 100 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    private var dotRowCount: Int {
        switch family {
        case .systemSmall:
            return 8
        case .systemMedium:
            return 12
        case .systemLarge:
            return 16
        default:
            return 8
        }
    }

    private var dotGraphHeight: CGFloat {
        switch family {
        case .systemSmall:
            return 28
        case .systemMedium:
            return 40
        case .systemLarge:
            return 56
        default:
            return 28
        }
    }

    private var graphColumnCount: Int {
        switch family {
        case .systemSmall:
            return 48
        case .systemMedium:
            return 96
        case .systemLarge:
            return 96
        default:
            return 48
        }
    }

    private func stackedSeriesBars(track2: WidgetSnapshot.Track2Summary?) -> [WidgetSnapshot.Track2Summary.StackedSeriesBar] {
        guard let track2 else {
            return []
        }

        let bars: [WidgetSnapshot.Track2Summary.StackedSeriesBar]
        if track2.stackedSeries24h.isEmpty == false {
            bars = track2.stackedSeries24h
        } else {
            bars = track2.series24h.map { bar in
                WidgetSnapshot.Track2Summary.StackedSeriesBar(
                    bucketStart: bar.bucketStart,
                    segments: [
                        WidgetSnapshot.Track2Summary.StackedSeriesBar.FamilySegment(
                            family: localizedString("widget.total"),
                            totalTokens: bar.totalTokens
                        ),
                    ]
                )
            }
        }

        return resampledBars(bars, targetCount: graphColumnCount)
    }

    private func resampledBars(
        _ source: [WidgetSnapshot.Track2Summary.StackedSeriesBar],
        targetCount: Int
    ) -> [WidgetSnapshot.Track2Summary.StackedSeriesBar] {
        guard source.isEmpty == false, targetCount > 0 else {
            return []
        }

        guard source.count > targetCount else {
            return source
        }

        var out: [WidgetSnapshot.Track2Summary.StackedSeriesBar] = []
        out.reserveCapacity(targetCount)

        for bucketIndex in 0..<targetCount {
            let start = source.count * bucketIndex / targetCount
            let nominalEnd = source.count * (bucketIndex + 1) / targetCount
            let end = min(source.count, max(start + 1, nominalEnd))

            guard start < source.count, start < end else {
                continue
            }

            let slice = source[start..<end]
            var familyTotals: [String: Int] = [:]
            for bar in slice {
                for segment in bar.segments where segment.totalTokens > 0 {
                    familyTotals[segment.family, default: 0] += segment.totalTokens
                }
            }

            let segments = familyTotals
                .map { family, total in
                    WidgetSnapshot.Track2Summary.StackedSeriesBar.FamilySegment(
                        family: family,
                        totalTokens: total
                    )
                }
                .sorted {
                    if $0.totalTokens != $1.totalTokens {
                        return $0.totalTokens > $1.totalTokens
                    }
                    return $0.family < $1.family
                }

            out.append(
                WidgetSnapshot.Track2Summary.StackedSeriesBar(
                    bucketStart: source[start].bucketStart,
                    segments: segments
                )
            )
        }

        return out
    }

    private func inferredBucketSeconds(from bars: [WidgetSnapshot.Track2Summary.StackedSeriesBar]) -> Int {
        guard bars.count >= 2 else {
            return 60 * 60
        }

        let delta = bars[1].bucketStart.timeIntervalSince(bars[0].bucketStart)
        return max(1, Int(delta.rounded()))
    }

    private func axisBars(from bars: [WidgetSnapshot.Track2Summary.StackedSeriesBar]) -> [WidgetSnapshot.Track2Summary.SeriesBar] {
        bars.map { bar in
            WidgetSnapshot.Track2Summary.SeriesBar(
                bucketStart: bar.bucketStart,
                totalTokens: bar.segments.map(\.totalTokens).reduce(0, +)
            )
        }
    }

    private var emptySnapshotView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provider.displayName)
                .font(.headline)
            Text("widget.empty_snapshot")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("widget.open_app_refresh")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private func localizedString(_ key: String) -> String {
    String(localized: String.LocalizationValue(key))
}

private struct DotStackedBarGraph: View {
    var bars: [WidgetSnapshot.Track2Summary.StackedSeriesBar]
    var maxDots: Int

    private let dotFillRatio: CGFloat = 0.78
    private let minimumDotDiameter: CGFloat = 1.8
    private let maximumDotDiameter: CGFloat = 4.4

    var body: some View {
        let layout = makeLayout()

        GeometryReader { proxy in
            let metrics = DotMetrics(
                size: proxy.size,
                columnCount: layout.columns.count,
                rowCount: maxDots,
                dotFillRatio: dotFillRatio,
                minimumDotDiameter: minimumDotDiameter,
                maximumDotDiameter: maximumDotDiameter
            )

            Canvas { context, _ in
                guard metrics.columnCount > 0,
                      metrics.rowCount > 0,
                      metrics.dotDiameter > 0
                else {
                    return
                }

                for columnIndex in 0..<layout.columns.count {
                    let column = layout.columns[columnIndex]
                    let centerX = metrics.columnCenterX(for: columnIndex)

                    for row in 0..<maxDots {
                        let centerY = metrics.rowCenterYFromBottom(for: row)
                        let rect = CGRect(
                            x: centerX - metrics.dotRadius,
                            y: centerY - metrics.dotRadius,
                            width: metrics.dotDiameter,
                            height: metrics.dotDiameter
                        )

                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(color(for: column[row], familyOrder: layout.familyOrder))
                        )
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func makeLayout() -> DotLayout {
        let maxTotal = bars
            .map { $0.segments.map(\.totalTokens).reduce(0, +) }
            .max() ?? 0

        var globalFamilyTotals: [String: Int] = [:]
        for bar in bars {
            for segment in bar.segments where segment.totalTokens > 0 {
                globalFamilyTotals[segment.family, default: 0] += segment.totalTokens
            }
        }

        let familyOrder = globalFamilyTotals
            .sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return $0.key < $1.key
            }
            .map(\.key)

        var columns: [[String?]] = []
        columns.reserveCapacity(bars.count)

        for bar in bars {
            var column = Array<String?>(repeating: nil, count: maxDots)
            let barTotal = bar.segments.map(\.totalTokens).reduce(0, +)

            if maxTotal > 0, barTotal > 0 {
                let scaledDots = Int((Double(barTotal) / Double(maxTotal) * Double(maxDots)).rounded())
                let totalDots = max(1, min(maxDots, scaledDots))

                var tokenByFamily: [String: Int] = [:]
                for segment in bar.segments where segment.totalTokens > 0 {
                    tokenByFamily[segment.family, default: 0] += segment.totalTokens
                }

                var orderedFamilyTotals: [(String, Int)] = familyOrder.compactMap { family in
                    guard let total = tokenByFamily[family], total > 0 else { return nil }
                    return (family, total)
                }

                if orderedFamilyTotals.isEmpty,
                   let fallback = bar.segments.first(where: { $0.totalTokens > 0 })
                {
                    orderedFamilyTotals = [(fallback.family, fallback.totalTokens)]
                }

                let allocations = allocateDots(totalDots: totalDots, familyTotals: orderedFamilyTotals)

                var cursor = 0
                for allocation in allocations {
                    for _ in 0..<allocation.count where cursor < maxDots {
                        column[cursor] = allocation.family
                        cursor += 1
                    }
                }
            }

            columns.append(column)
        }

        return DotLayout(familyOrder: familyOrder, columns: columns)
    }

    private func color(for family: String?, familyOrder: [String]) -> Color {
        guard let family,
              let index = familyOrder.firstIndex(of: family)
        else {
            return .secondary.opacity(0.14)
        }

        return track2FamilyPalette[index % track2FamilyPalette.count].opacity(0.9)
    }

    private func allocateDots(totalDots: Int, familyTotals: [(String, Int)]) -> [DotAllocation] {
        guard totalDots > 0 else { return [] }

        let tokenTotal = familyTotals.map(\.1).reduce(0, +)
        guard tokenTotal > 0 else { return [] }

        var allocations: [DotAllocation] = familyTotals.enumerated().map { index, entry in
            let raw = Double(entry.1) * Double(totalDots) / Double(tokenTotal)
            let base = Int(raw.rounded(.down))
            let fraction = raw - Double(base)
            return DotAllocation(family: entry.0, count: base, fraction: fraction, tokens: entry.1, order: index)
        }

        var assigned = allocations.map(\.count).reduce(0, +)
        var remainder = totalDots - assigned

        if remainder > 0 {
            let ranked = allocations
                .indices
                .sorted {
                    if allocations[$0].fraction != allocations[$1].fraction {
                        return allocations[$0].fraction > allocations[$1].fraction
                    }
                    if allocations[$0].tokens != allocations[$1].tokens {
                        return allocations[$0].tokens > allocations[$1].tokens
                    }
                    if allocations[$0].family != allocations[$1].family {
                        return allocations[$0].family < allocations[$1].family
                    }
                    return allocations[$0].order < allocations[$1].order
                }

            var index = 0
            while remainder > 0, ranked.isEmpty == false {
                let target = ranked[index % ranked.count]
                allocations[target].count += 1
                remainder -= 1
                index += 1
            }
            assigned = allocations.map(\.count).reduce(0, +)
        }

        if assigned < totalDots,
           let first = allocations.indices.first
        {
            allocations[first].count += (totalDots - assigned)
        }

        return allocations.filter { $0.count > 0 }
    }

    private struct DotLayout {
        var familyOrder: [String]
        var columns: [[String?]]
    }

    private struct DotMetrics {
        let width: CGFloat
        let height: CGFloat
        let columnCount: Int
        let rowCount: Int
        let columnStep: CGFloat
        let rowStep: CGFloat
        let leadingInset: CGFloat
        let dotDiameter: CGFloat

        var dotRadius: CGFloat { dotDiameter / 2 }

        init(
            size: CGSize,
            columnCount: Int,
            rowCount: Int,
            dotFillRatio: CGFloat,
            minimumDotDiameter: CGFloat,
            maximumDotDiameter: CGFloat
        ) {
            width = max(0, size.width)
            height = max(0, size.height)
            self.columnCount = max(0, columnCount)
            self.rowCount = max(0, rowCount)
            rowStep = self.rowCount > 0 ? height / CGFloat(self.rowCount) : 0

            columnStep = self.columnCount > 0 ? width / CGFloat(self.columnCount) : 0
            leadingInset = 0

            let cell = min(columnStep, rowStep)
            let target = cell * dotFillRatio
            let fitLimit = cell * 0.92

            if fitLimit > 0 {
                dotDiameter = min(
                    fitLimit,
                    min(
                        maximumDotDiameter,
                        max(minimumDotDiameter, target)
                    )
                )
            } else {
                dotDiameter = 0
            }
        }

        func columnCenterX(for index: Int) -> CGFloat {
            leadingInset + (CGFloat(index) + 0.5) * columnStep
        }

        func rowCenterYFromBottom(for row: Int) -> CGFloat {
            height - (CGFloat(row) + 0.5) * rowStep
        }
    }

    private struct DotAllocation {
        var family: String
        var count: Int
        var fraction: Double
        var tokens: Int
        var order: Int
    }
}

private struct MiniBarAxisLabels: View {
    var bars: [WidgetSnapshot.Track2Summary.SeriesBar]
    var bucketSeconds: Int

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH'h'"
        return formatter
    }()

    private static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 0) {
            Text(label(for: 0))
            Spacer(minLength: 6)
            Text(label(for: bars.count / 2))
            Spacer(minLength: 6)
            Text(label(for: max(0, bars.count - 1)))
        }
        .font(.system(size: 8, weight: .regular, design: .rounded))
        .foregroundStyle(.tertiary)
    }

    private func label(for index: Int) -> String {
        guard bars.indices.contains(index) else {
            return "--"
        }

        let date = bars[index].bucketStart
        if bucketSeconds < 60 * 60 {
            return Self.minuteFormatter.string(from: date)
        }
        return Self.hourFormatter.string(from: date)
    }
}

struct TokenMeterCodexWidget: Widget {
    var body: some WidgetConfiguration {
        ProviderWidgetConfiguration.make(
            kind: WidgetSharedConfig.codexWidgetKind,
            provider: .codex,
            displayNameKey: "widget.config.codex.name",
            descriptionKey: "widget.config.codex.description"
        )
    }
}

struct TokenMeterClaudeWidget: Widget {
    var body: some WidgetConfiguration {
        ProviderWidgetConfiguration.make(
            kind: WidgetSharedConfig.claudeWidgetKind,
            provider: .claude,
            displayNameKey: "widget.config.claude.name",
            descriptionKey: "widget.config.claude.description"
        )
    }
}

@MainActor
private enum ProviderWidgetConfiguration {
    private static let supportedFamilies: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]

    static func make(kind: String, provider: WidgetProvider, displayNameKey: String, descriptionKey: String) -> some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TokenMeterWidgetProvider()) { entry in
            providerContent(entry: entry, provider: provider)
        }
        .configurationDisplayName(localizedString(displayNameKey))
        .description(localizedString(descriptionKey))
        .supportedFamilies(supportedFamilies)
    }

    @ViewBuilder
    private static func providerContent(entry: TokenMeterWidgetProvider.Entry, provider: WidgetProvider) -> some View {
        if #available(macOS 14.0, *) {
            TokenMeterProviderWidgetView(entry: entry, provider: provider)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        } else {
            TokenMeterProviderWidgetView(entry: entry, provider: provider)
        }
    }
}

@main
struct TokenMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        TokenMeterCodexWidget()
        TokenMeterClaudeWidget()
    }
}
