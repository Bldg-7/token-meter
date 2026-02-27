import Foundation
import Charts
import SwiftUI
import Combine

struct ContentView: View {
    @State private var enabledProviders: [ProviderId] = [.codex, .claude]
    @State private var track1LatestByProvider: [ProviderId: Track1Snapshot] = [:]
    @State private var track2AllPoints: [Track2TimelinePoint] = []
    @State private var track2RecentByProvider: [ProviderId: [Track2TimelinePoint]] = [:]
    @State private var widgetTrack2TimeScale: Track2WidgetTimeScale = .hours24
    @State private var widgetTrack2TimeScaleDraft: Track2WidgetTimeScale = .hours24
    @State private var showWidgetRangeOptions: Bool = false
    @State private var track2Range: Track2Range = .hours24
    @State private var track2ProviderSelection: Track2ProviderSelection = .all
    @State private var loadError: String?

  var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .center, spacing: 8) {
                Text(
                    String(
                        format: NSLocalizedString("content.widget_range_format", comment: "Widget range label"),
                        widgetTrack2TimeScale.rawValue
                    )
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button("content.time_range_options") {
                    widgetTrack2TimeScaleDraft = widgetTrack2TimeScale
                    showWidgetRangeOptions = true
                }
                .font(.caption2)
                .popover(isPresented: $showWidgetRangeOptions, arrowEdge: .top) {
                    WidgetTimeRangeOptionsSheet(
                        selectedScale: $widgetTrack2TimeScaleDraft,
                        onCancel: {
                            showWidgetRangeOptions = false
                        },
                        onApply: {
                            let scale = widgetTrack2TimeScaleDraft
                            Task {
                                await applyWidgetTrack2Range(scale)
                            }
                        }
                    )
                }
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("content.track1_note")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if enabledProviders.isEmpty {
                        Text("content.no_providers_enabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(enabledProviders, id: \.rawValue) { provider in
                            Track1ProviderCard(
                                provider: provider,
                                snapshot: track1LatestByProvider[provider]
                            )
                        }
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if enabledProviders.isEmpty {
                        Text("content.no_providers_enabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Track2TrendsCard(
                            enabledProviders: enabledProviders,
                            allPoints: track2AllPoints,
                            range: $track2Range,
                            providerSelection: $track2ProviderSelection
                        )

                        ForEach(enabledProviders, id: \.rawValue) { provider in
                            Track2ProviderCard(
                                provider: provider,
                                points: track2RecentByProvider[provider] ?? []
                            )
                        }
                    }
                }
            }
        }
        // Quit button in menu popover (localized label key: menu.quit)
        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            Text(NSLocalizedString("menu.quit", comment: "Quit app"))
        }
        .padding(16)
        .frame(width: 360)
    .task {
      await reload()
    }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TokenMeterStoreDidUpdate"))) { _ in
      Task { await reload() }
    }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("app.title")
                .font(.headline)

            Text("menu.status.notCollecting")
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func reload() async {
        do {
            let settings = try await SettingsStore.shared.load()

            var providers: [ProviderId] = []
            if settings.codex.enabled { providers.append(.codex) }
            if settings.claude.enabled { providers.append(.claude) }
            enabledProviders = providers

            let track1Store = Track1Store()
            let track2Store = Track2Store()

            let snapshots = try await track1Store.loadAll()
            let points = try await track2Store.loadAll()

            track1LatestByProvider = Self.latestTrack1Snapshots(snapshots)
            track2AllPoints = points
            track2RecentByProvider = Self.recentTrack2Points(points, maxPerProvider: 12)
            widgetTrack2TimeScale = settings.widgetTrack2TimeScale

            if let selected = track2ProviderSelection.providerId, enabledProviders.contains(selected) == false {
                track2ProviderSelection = .all
            }
            loadError = nil
        } catch {
            loadError = String(
                format: NSLocalizedString("content.error.load", comment: "Load error"),
                String(describing: error)
            )
        }
    }

    @MainActor
    private func applyWidgetTrack2Range(_ scale: Track2WidgetTimeScale) async {
        do {
            var settings = try await SettingsStore.shared.load()
            settings.widgetTrack2TimeScale = scale
            try await SettingsStore.shared.save(settings)
            try await WidgetSnapshotRefresher().refresh(settings: settings)
            NotificationCenter.default.post(name: Notification.Name("TokenMeterStoreDidUpdate"), object: nil)
            widgetTrack2TimeScale = scale
            showWidgetRangeOptions = false
            loadError = nil
        } catch {
            loadError = String(
                format: NSLocalizedString("content.error.save_widget_range", comment: "Save widget range error"),
                String(describing: error)
            )
        }
    }

    private static func latestTrack1Snapshots(_ snapshots: [Track1Snapshot]) -> [ProviderId: Track1Snapshot] {
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

    private static func recentTrack2Points(
        _ points: [Track2TimelinePoint],
        maxPerProvider: Int
    ) -> [ProviderId: [Track2TimelinePoint]] {
        let grouped = Dictionary(grouping: points, by: { $0.provider })
        var out: [ProviderId: [Track2TimelinePoint]] = [:]
        out.reserveCapacity(grouped.count)

        for (provider, pts) in grouped {
            let recent = pts
                .sorted(by: { $0.timestamp < $1.timestamp })
                .suffix(max(1, maxPerProvider))
            out[provider] = Array(recent)
        }

        return out
    }
}

private struct WidgetTimeRangeOptionsSheet: View {
    @Binding var selectedScale: Track2WidgetTimeScale
    var onCancel: () -> Void
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("content.widget_time_range.title")
                .font(.headline)

            Picker("content.widget_time_range.range", selection: $selectedScale) {
                ForEach(Track2WidgetTimeScale.allCases) { scale in
                    Text(scale.rawValue).tag(scale)
                }
            }
            .pickerStyle(.menu)

            Text("content.widget_time_range.help")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("common.cancel", action: onCancel)
                Button("common.apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private enum Track2Range: String, CaseIterable, Identifiable {
    case hours24 = "24h"
    case days7 = "7d"
    case days30 = "30d"

    var id: String { rawValue }

    var durationSeconds: TimeInterval {
        switch self {
        case .hours24:
            return 24 * 60 * 60
        case .days7:
            return 7 * 24 * 60 * 60
        case .days30:
            return 30 * 24 * 60 * 60
        }
    }

    func startDate(now: Date = Date()) -> Date {
        now.addingTimeInterval(-durationSeconds)
    }

    var bucketComponent: Calendar.Component {
        switch self {
        case .hours24:
            return .hour
        case .days7, .days30:
            return .day
        }
    }
}

private enum Track2ProviderSelection: Hashable {
    case all
    case provider(ProviderId)

    var providerId: ProviderId? {
        switch self {
        case .all:
            return nil
        case .provider(let provider):
            return provider
        }
    }
}

private struct Track2TrendsCard: View {
    var enabledProviders: [ProviderId]
    var allPoints: [Track2TimelinePoint]
    @Binding var range: Track2Range
    @Binding var providerSelection: Track2ProviderSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Picker("content.track2.range", selection: $range) {
                    ForEach(Track2Range.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Picker("content.track2.provider", selection: $providerSelection) {
                    Text("content.track2.provider_all").tag(Track2ProviderSelection.all)
                    ForEach(enabledProviders, id: \.rawValue) { provider in
                        Text(provider.rawValue.uppercased())
                            .tag(Track2ProviderSelection.provider(provider))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
            }

            Text("content.track2.local_telemetry_note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if bucketedSeries.isEmpty {
                Text("content.track2.no_points_in_range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                chart
                    .frame(height: 90)
                    .padding(.vertical, 2)
            }

            Track2ModelBreakdownSummary(summary: breakdown)
        }
        .padding(10)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filteredPoints: [Track2TimelinePoint] {
        let now = Date()
        let start = range.startDate(now: now)

        return allPoints.filter { pt in
            guard enabledProviders.contains(pt.provider) else { return false }
            guard pt.timestamp >= start && pt.timestamp <= now else { return false }
            if let provider = providerSelection.providerId {
                return pt.provider == provider
            }
            return true
        }
        .sorted(by: { $0.timestamp < $1.timestamp })
    }

    private struct Track2Bucket: Identifiable {
        var id: Date { bucketStart }
        var bucketStart: Date
        var totalTokens: Int
    }

    private var bucketedSeries: [Track2Bucket] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filteredPoints) { pt in
            cal.dateInterval(of: range.bucketComponent, for: pt.timestamp)?.start ?? pt.timestamp
        }

        let buckets: [Track2Bucket] = grouped.map { (bucketStart, pts) in
            let total = pts
                .compactMap { Self.totalTokens(for: $0) }
                .reduce(0, +)
            return Track2Bucket(bucketStart: bucketStart, totalTokens: total)
        }

        return buckets.sorted(by: { $0.bucketStart < $1.bucketStart })
    }

    @ViewBuilder
    private var chart: some View {
        if #available(macOS 13.0, *) {
            Chart(bucketedSeries) { bucket in
                AreaMark(
                    x: .value("Time", bucket.bucketStart),
                    y: .value("Tokens", bucket.totalTokens)
                )
                .foregroundStyle(.secondary.opacity(0.16))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", bucket.bucketStart),
                    y: .value("Tokens", bucket.totalTokens)
                )
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 2)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                }
            }
        } else {
            MiniBarGraph(values: bucketedSeries.map { $0.totalTokens })
        }
    }

    fileprivate struct Breakdown {
        var totalTokens: Int
        var pointsCount: Int
        var sessionsCount: Int
        var byModel: [ModelItem]

        fileprivate struct ModelItem: Identifiable {
            var id: String { model }
            var model: String
            var tokens: Int
            var points: Int
        }
    }

    private var breakdown: Breakdown {
        let pts = filteredPoints
        let totalTokens = pts.compactMap { Self.totalTokens(for: $0) }.reduce(0, +)
        let sessionsCount = Set(pts.compactMap { $0.sessionId }.filter { $0.isEmpty == false }).count

        let groups = Dictionary(grouping: pts) { pt in
            let m = (pt.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "unknown" : m
        }

        let byModel: [Breakdown.ModelItem] = groups.map { (model, pts) in
            let tokens = pts.compactMap { Self.totalTokens(for: $0) }.reduce(0, +)
            return Breakdown.ModelItem(model: model, tokens: tokens, points: pts.count)
        }
        .sorted {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.model < $1.model
        }

        return Breakdown(
            totalTokens: totalTokens,
            pointsCount: pts.count,
            sessionsCount: sessionsCount,
            byModel: byModel
        )
    }

    private static func totalTokens(for point: Track2TimelinePoint) -> Int? {
        if let total = point.totalTokens { return total }
        if let p = point.promptTokens, let c = point.completionTokens { return p + c }
        return nil
    }
}

private struct Track2ModelBreakdownSummary: View {
    var summary: Track2TrendsCard.Breakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(localizedFormat("content.track2.points_format", summary.pointsCount))
                if summary.sessionsCount > 0 {
                    Text(localizedFormat("content.track2.sessions_format", summary.sessionsCount))
                }
                Text(localizedFormat("content.track2.tokens_format", summary.totalTokens))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            if summary.byModel.isEmpty {
                Text("content.track2.no_model_breakdown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.byModel.prefix(4)) { item in
                    HStack(spacing: 8) {
                        Text(item.model)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text("\(item.tokens)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("(\(item.points))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func localizedFormat(_ key: String, _ value: Int) -> String {
        String(format: NSLocalizedString(key, comment: ""), value)
    }
}

private struct Track1ProviderCard: View {
    var provider: ProviderId
    var snapshot: Track1Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.rawValue.uppercased())
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                if let snapshot {
                    HealthBadge(status: TrackHealthStatus.from(ageSec: Date().timeIntervalSince(snapshot.observedAt)))
                    Badge(
                        text: String(
                            format: NSLocalizedString("content.badge.source_format", comment: "Source badge"),
                            localizedTrack1SourceLabel(snapshot.source)
                        )
                    )
                    Badge(
                        text: String(
                            format: NSLocalizedString("content.badge.confidence_format", comment: "Confidence badge"),
                            localizedTrackConfidenceLabel(snapshot.confidence)
                        )
                    )
                } else {
                    HealthBadge(status: .missing)
                }
            }

            Badge(text: planBadgeText)

            if let snapshot {
                let visibleWindows = menuVisibleWindows(from: snapshot)
                if visibleWindows.isEmpty == false {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleWindows.indices, id: \.self) { idx in
                            Track1WindowRow(window: visibleWindows[idx])
                        }
                    }
                }
            } else {
                Text("content.track1.no_data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var planBadgeText: String {
        guard let snapshot else {
            return NSLocalizedString("content.plan.unknown", comment: "Unknown plan badge")
        }

        if snapshot.plan == .unknown {
            return NSLocalizedString("content.plan.unknown", comment: "Unknown plan badge")
        }

        return String(
            format: NSLocalizedString("content.plan.value_format", comment: "Plan badge with plan value"),
            localizedTrack1PlanLabel(snapshot.plan)
        )
    }

    private func menuVisibleWindows(from snapshot: Track1Snapshot) -> [Track1Window] {
        snapshot.windows.filter { window in
            window.windowId != .rolling5h
                && window.windowId != .weekly
                && window.windowId != .modelSpecific
        }
    }
}

private struct Track1WindowRow: View {
    var window: Track1Window

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(localizedTrack1WindowTitle(window.windowId))
                    .font(.caption2.weight(.semibold))

                Spacer(minLength: 8)

                if let usedPercent = window.usedPercent {
                    Text("\(Int(usedPercent.rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let usedPercent = window.usedPercent {
                ProgressView(value: usedPercent / 100.0)
                    .controlSize(.small)
            } else {
                Text(localizedTrack1ScopeLabel(window.rawScopeLabel))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let resetAt = window.resetAt {
                HStack(spacing: 4) {
                    Text("content.track1.resets")
                    Text(resetAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct Track2ProviderCard: View {
    var provider: ProviderId
    var points: [Track2TimelinePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.rawValue.uppercased())
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                if let last = points.last {
                    HealthBadge(status: TrackHealthStatus.from(ageSec: Date().timeIntervalSince(last.timestamp)))
                    Badge(
                        text: String(
                            format: NSLocalizedString("content.badge.confidence_format", comment: "Confidence badge"),
                            localizedTrackConfidenceLabel(last.confidence)
                        )
                    )
                    Badge(
                        text: String(
                            format: NSLocalizedString("content.badge.source_format", comment: "Source badge"),
                            Self.sourceLabel(from: last.sourceFile)
                        )
                    )
                } else {
                    HealthBadge(status: .missing)
                }
            }

            if points.isEmpty {
                Text("content.track2.no_data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                MiniBarGraph(values: points.compactMap { Self.totalTokens(for: $0) })
                    .frame(height: 26)

                if let last = points.last {
                    Text(Self.lastPointSummary(last))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func totalTokens(for point: Track2TimelinePoint) -> Int? {
        if let total = point.totalTokens { return total }
        if let p = point.promptTokens, let c = point.completionTokens { return p + c }
        return nil
    }

    private static func sourceLabel(from sourceFile: String) -> String {
        let url = URL(fileURLWithPath: sourceFile)
        let name = url.lastPathComponent
        return name.isEmpty ? sourceFile : name
    }

    private static func lastPointSummary(_ point: Track2TimelinePoint) -> String {
        var parts: [String] = []
        if let model = point.model, model.isEmpty == false {
            parts.append(model)
        }
        if let total = totalTokens(for: point) {
            parts.append(
                String(
                    format: NSLocalizedString("content.track2.total_format", comment: "Track2 last point total"),
                    total
                )
            )
        }
        parts.append(relativeString(from: point.timestamp))
        return parts.joined(separator: " | ")
    }

    private static func relativeString(from date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private func localizedTrackConfidenceLabel(_ confidence: TrackConfidence) -> String {
    switch confidence {
    case .high:
        return NSLocalizedString("content.badge.confidence.high", comment: "High confidence")
    case .medium:
        return NSLocalizedString("content.badge.confidence.medium", comment: "Medium confidence")
    case .low:
        return NSLocalizedString("content.badge.confidence.low", comment: "Low confidence")
    }
}

private func localizedTrack1SourceLabel(_ source: Track1Source) -> String {
    switch source {
    case .cliMethodB:
        return NSLocalizedString("content.badge.source.cli_method_b", comment: "CLI Method B source")
    case .webMethodC:
        return NSLocalizedString("content.badge.source.web_method_c", comment: "Web Method C source")
    }
}

private func localizedTrack1PlanLabel(_ plan: Track1PlanLabel) -> String {
    switch plan {
    case .free:
        return NSLocalizedString("content.plan.free", comment: "Free plan")
    case .plus:
        return NSLocalizedString("content.plan.plus", comment: "Plus plan")
    case .pro:
        return NSLocalizedString("content.plan.pro", comment: "Pro plan")
    case .max:
        return NSLocalizedString("content.plan.max", comment: "Max plan")
    case .team:
        return NSLocalizedString("content.plan.team", comment: "Team plan")
    case .business:
        return NSLocalizedString("content.plan.business", comment: "Business plan")
    case .enterprise:
        return NSLocalizedString("content.plan.enterprise", comment: "Enterprise plan")
    case .unknown:
        return NSLocalizedString("content.plan.unknown_value", comment: "Unknown plan value")
    }
}

private func localizedTrack1WindowTitle(_ windowId: Track1WindowId) -> String {
    switch windowId {
    case .session:
        return NSLocalizedString("content.track1.window.session", comment: "Session window title")
    case .rolling5h:
        return NSLocalizedString("content.track1.window.rolling_5h", comment: "Rolling 5h window title")
    case .weekly:
        return NSLocalizedString("content.track1.window.weekly", comment: "Weekly window title")
    case .modelSpecific:
        return NSLocalizedString("content.track1.window.model_specific", comment: "Model-specific window title")
    }
}

private func localizedTrack1ScopeLabel(_ rawScopeLabel: String) -> String {
    let trimmed = rawScopeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
        return NSLocalizedString("content.track1.scope.unknown", comment: "Unknown scope label")
    }

    switch trimmed.lowercased() {
    case "codex":
        return NSLocalizedString("content.track1.scope.codex", comment: "Codex scope label")
    case "claude":
        return NSLocalizedString("content.track1.scope.claude", comment: "Claude scope label")
    case "session":
        return localizedTrack1WindowTitle(.session)
    case "rolling_5h":
        return localizedTrack1WindowTitle(.rolling5h)
    case "weekly":
        return localizedTrack1WindowTitle(.weekly)
    case "model_specific":
        return localizedTrack1WindowTitle(.modelSpecific)
    default:
        return humanizedTrackScopeLabel(trimmed)
    }
}

private func humanizedTrackScopeLabel(_ value: String) -> String {
    let normalized = value
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    return normalized.isEmpty ? value : normalized
}

private enum TrackHealthStatus: String {
    case ok
    case stale
    case missing

    static func from(ageSec: TimeInterval) -> TrackHealthStatus {
        if ageSec.isNaN || ageSec.isInfinite {
            return .missing
        }
        if ageSec < 2 * 60 {
            return .ok
        }
        if ageSec < 15 * 60 {
            return .stale
        }
        return .missing
    }
}

private struct HealthBadge: View {
    var status: TrackHealthStatus

    var body: some View {
        Badge(
            text: String(
                format: NSLocalizedString("content.badge.health_format", comment: "Health badge"),
                localizedStatusLabel
            ),
            role: role
        )
    }

    private var role: BadgeRole {
        switch status {
        case .ok:
            return .good
        case .stale:
            return .warn
        case .missing:
            return .bad
        }
    }

    private var localizedStatusLabel: String {
        switch status {
        case .ok:
            return NSLocalizedString("content.badge.health.ok", comment: "Health ok")
        case .stale:
            return NSLocalizedString("content.badge.health.stale", comment: "Health stale")
        case .missing:
            return NSLocalizedString("content.badge.health.missing", comment: "Health missing")
        }
    }
}

private enum BadgeRole {
    case neutral
    case good
    case warn
    case bad
}

private struct Badge: View {
    var text: String
    var role: BadgeRole = .neutral

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(Capsule())
    }

    private var foreground: Color {
        switch role {
        case .neutral:
            return .secondary
        case .good:
            return Color(nsColor: .systemGreen)
        case .warn:
            return Color(nsColor: .systemOrange)
        case .bad:
            return Color(nsColor: .systemRed)
        }
    }

    private var background: some ShapeStyle {
        switch role {
        case .neutral:
            return AnyShapeStyle(.quaternary.opacity(0.25))
        case .good:
            return AnyShapeStyle(Color(nsColor: .systemGreen).opacity(0.12))
        case .warn:
            return AnyShapeStyle(Color(nsColor: .systemOrange).opacity(0.12))
        case .bad:
            return AnyShapeStyle(Color(nsColor: .systemRed).opacity(0.12))
        }
    }
}

private struct MiniBarGraph: View {
    var values: [Int]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let maxValue = max(1, values.max() ?? 1)
            let count = max(1, values.count)
            let spacing: CGFloat = 3
            let barWidth = max(2, (size.width - (CGFloat(count - 1) * spacing)) / CGFloat(count))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(values.indices, id: \.self) { idx in
                    let value = values[idx]
                    let fraction = CGFloat(value) / CGFloat(maxValue)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.secondary.opacity(0.35))
                        .frame(width: barWidth, height: max(2, size.height * fraction))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
