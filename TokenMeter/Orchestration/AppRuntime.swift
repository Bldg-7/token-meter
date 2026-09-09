import Foundation
import Dispatch
import SwiftUI
import SQLite3

@MainActor
final class AppRuntime: ObservableObject {
    private var orchestrator: CollectionOrchestrator?
    private var widgetSnapshotRefresher: WidgetSnapshotRefresher?
    private let track1Store = Track1Store()
    private let track2Store = Track2Store()
    private let collector = ProviderCollectionRuntime(environment: ProcessInfo.processInfo.environment)

    init() {
        Task {
            await startIfNeeded()
        }
    }

    private func startIfNeeded() async {
        if orchestrator != nil {
            return
        }

        let settings: AppSettings
        do {
            settings = try await SettingsStore.shared.load()
        } catch {
            DiagnosticsLogger(provider: .codex).error("settings_load_failed", fields: ["error": .string(String(describing: error))])
            DiagnosticsLogger(provider: .claude).error("settings_load_failed", fields: ["error": .string(String(describing: error))])
            return
        }

        let periodNs = UInt64(max(1, settings.refreshIntervalSec)) * 1_000_000_000
        // Claude quota windows are 5h/weekly, so polling faster than this buys
        // nothing and only risks the /api/oauth/usage rate limit.
        let claudeTrack1MinPeriodNs: UInt64 = 15 * 60 * 1_000_000_000
        let claudeTrack1PeriodNs = max(periodNs * 5, claudeTrack1MinPeriodNs)
        let track1TimeoutNs: UInt64 = 2 * 1_000_000_000
        let track2TimeoutNs: UInt64 = 15 * 1_000_000_000

        var units: [CollectionUnit] = []
        units.reserveCapacity(4)
        // Inject shared stores into the widget snapshot refresher to avoid stale caches on first-run
        let snapshotRefresher: WidgetSnapshotRefresher
        if let existing = widgetSnapshotRefresher {
            snapshotRefresher = existing
        } else {
            let newRefresher = WidgetSnapshotRefresher(track1Store: track1Store, track2Store: track2Store)
            widgetSnapshotRefresher = newRefresher
            snapshotRefresher = newRefresher
        }

        do {
            try await snapshotRefresher.refresh(settings: settings)
        } catch {
            DiagnosticsLogger(provider: .codex).error("widget_snapshot_refresh_failed", fields: ["error": .string(String(describing: error))])
            DiagnosticsLogger(provider: .claude).error("widget_snapshot_refresh_failed", fields: ["error": .string(String(describing: error))])
        }

        if settings.codex.enabled {
            units.append(
                collectionUnit(
                    provider: .codex,
                    track: .track1,
                    periodNs: periodNs,
                    timeoutNs: track1TimeoutNs,
                    settings: settings,
                    snapshotRefresher: snapshotRefresher
                )
            )
            units.append(
                collectionUnit(
                    provider: .codex,
                    track: .track2,
                    periodNs: periodNs,
                    timeoutNs: track2TimeoutNs,
                    settings: settings,
                    snapshotRefresher: snapshotRefresher
                )
            )
        }
        if settings.claude.enabled {
            units.append(
                collectionUnit(
                    provider: .claude,
                    track: .track1,
                    periodNs: claudeTrack1PeriodNs,
                    timeoutNs: track1TimeoutNs,
                    settings: settings,
                    snapshotRefresher: snapshotRefresher
                )
            )
            units.append(
                collectionUnit(
                    provider: .claude,
                    track: .track2,
                    periodNs: periodNs,
                    timeoutNs: track2TimeoutNs,
                    settings: settings,
                    snapshotRefresher: snapshotRefresher
                )
            )
        }

        let orchestrator = CollectionOrchestrator(
            clock: SystemOrchestratorClock(),
            units: units,
            healthDidChange: { key, health in
                DiagnosticsLogger(provider: key.provider).debug(
                    "collection_health",
                    fields: [
                        "track": .string(key.track.rawValue),
                        "phase": .string(AppRuntime.phaseString(health.phase)),
                        "consecutiveFailures": .int(health.consecutiveFailures),
                        "lastError": health.lastError.map { .string($0) } ?? .null,
                    ]
                )
            }
        )
        self.orchestrator = orchestrator
        await orchestrator.start()
    }

    private func collectionUnit(
        provider: ProviderId,
        track: CollectionTrackId,
        periodNs: UInt64,
        timeoutNs: UInt64,
        settings: AppSettings,
        snapshotRefresher: WidgetSnapshotRefresher
    ) -> CollectionUnit {
        let key = CollectionRefreshKey(provider: provider, track: track)
        let collector = self.collector
        let track1Store = self.track1Store
        let track2Store = self.track2Store
        return CollectionUnit(
            key: key,
            config: CollectionUnitConfig(periodNanoseconds: periodNs, timeoutNanoseconds: timeoutNs),
            operation: {
                let logger = DiagnosticsLogger(provider: provider)
                let runtimeSettings: AppSettings
                do {
                    runtimeSettings = try await SettingsStore.shared.load()
                } catch {
                    runtimeSettings = settings
                    logger.error(
                        "settings_reload_failed",
                        fields: ["error": .string(String(describing: error))]
                    )
                }

                switch track {
                case .track1:
                    let snapshot = try collector.collectTrack1Snapshot(provider: provider, settings: runtimeSettings)
                    try await track1Store.append(snapshot)
                    logger.info(
                        "collection_track1_success",
                        fields: [
                            "track": .string(track.rawValue),
                            "source": .string(snapshot.source.rawValue),
                            "windows": .int(snapshot.windows.count),
                        ]
                    )
                case .track2:
                    let points = try collector.collectTrack2Points(provider: provider)
                    let persistedCount = try await collector.persistTrack2Points(points, store: track2Store)
                    logger.info(
                        "collection_track2_success",
                        fields: [
                            "track": .string(track.rawValue),
                            "pointsCollected": .int(points.count),
                            "pointsPersisted": .int(persistedCount),
                        ]
                    )
                    guard persistedCount > 0 else {
                        return
                    }
                }

                try await snapshotRefresher.refresh(settings: runtimeSettings)
                // Notify that in-memory store has updated for this run; UI/widget should refresh to reflect new data
                NotificationCenter.default.post(name: Notification.Name("TokenMeterStoreDidUpdate"), object: nil)
            }
        )
    }

    nonisolated private static func phaseString(_ phase: CollectionUnitPhase) -> String {
        switch phase {
        case .idle:
            return "idle"
        case .sleeping:
            return "sleeping"
        case .running:
            return "running"
        case .backingOff:
            return "backing_off"
        case .stopped:
            return "stopped"
        }
    }
}

enum CollectionPipelineError: Error {
    case toolNotFound(provider: ProviderId)
    case commandFailed(provider: ProviderId)
    case emptyOutput(provider: ProviderId)
}

/// Anthropic throttles `/api/oauth/usage` far more aggressively than our poll
/// period: a 429 there carries a Retry-After of ~30 minutes. Requesting again
/// inside that window renews the penalty, so once throttled the app never
/// escapes on its own. Hold off until Retry-After elapses instead.
final class ClaudeOAuthUsageThrottle: @unchecked Sendable {
    static let defaultCooldownSec: TimeInterval = 30 * 60

    private let lock = NSLock()
    private var retryAt: Date?

    /// Seconds still to wait, or nil when a request may go out.
    func remainingCooldown(now: Date = Date()) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let retryAt, retryAt > now else { return nil }
        return retryAt.timeIntervalSince(now)
    }

    func noteThrottled(retryAfterHeader: String?, now: Date = Date()) {
        let cooldown = Self.parseRetryAfter(retryAfterHeader, now: now) ?? Self.defaultCooldownSec
        lock.lock()
        defer { lock.unlock() }
        retryAt = now.addingTimeInterval(cooldown)
    }

    func noteSucceeded() {
        lock.lock()
        defer { lock.unlock() }
        retryAt = nil
    }

    /// Retry-After is either delta-seconds or an HTTP-date (RFC 7231).
    static func parseRetryAfter(_ raw: String?, now: Date = Date()) -> TimeInterval? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false
        else { return nil }

        if let seconds = TimeInterval(trimmed) {
            return seconds > 0 ? seconds : nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }

        let delta = date.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }
}

struct ProviderCollectionRuntime: Sendable {
    private static let openCodeTrack2ParserVersion = "opencode_track2_message_v1"
    /// A pi session header is a single short JSON line; this only has to be
    /// large enough to contain it.
    private static let piSessionHeaderProbeBytes = 8 * 1024
    private static let track2ContextTailBytes = 64 * 1024
    private static let track2IncrementalState = Track2IncrementalState()
    private static let claudeOAuthUsageThrottle = ClaudeOAuthUsageThrottle()

    struct ProcessRunner: Sendable {
        enum Mode: Sendable {
            case live
            case custom
        }

        var mode: Mode
        var run: @Sendable (_ executableURL: URL, _ arguments: [String], _ stdinData: Data?) throws -> ProcessRunResult

        init(run: @escaping @Sendable (_ executableURL: URL, _ arguments: [String], _ stdinData: Data?) throws -> ProcessRunResult) {
            mode = .custom
            self.run = run
        }

        init(run: @escaping @Sendable (_ executableURL: URL, _ arguments: [String]) throws -> ProcessRunResult) {
            mode = .custom
            self.run = { executableURL, arguments, _ in
                try run(executableURL, arguments)
            }
        }

        private init(mode: Mode, run: @escaping @Sendable (_ executableURL: URL, _ arguments: [String], _ stdinData: Data?) throws -> ProcessRunResult) {
            self.mode = mode
            self.run = run
        }

        func execute(_ executableURL: URL, _ arguments: [String], stdinData: Data? = nil) throws -> ProcessRunResult {
            try run(executableURL, arguments, stdinData)
        }

        static let live = ProcessRunner(mode: .live, run: { executableURL, arguments, stdinData in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            var stdinPipe: Pipe?
            if stdinData != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
            }

            try process.run()

            if let stdinData, let handle = stdinPipe?.fileHandleForWriting {
                handle.write(stdinData)
                try? handle.close()
            }

            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

            return ProcessRunResult(
                status: process.terminationStatus,
                stdout: stdoutData,
                stderr: stderrData
            )
        })
    }

    struct ProcessRunResult: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    struct HTTPRunResult: Sendable {
        var statusCode: Int
        var body: Data
        var headers: [String: String] = [:]

        func header(_ name: String) -> String? {
            headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
        }
    }

    struct HTTPRunner: Sendable {
        var run: @Sendable (_ request: URLRequest, _ timeoutSec: TimeInterval) throws -> HTTPRunResult

        func execute(_ request: URLRequest, timeoutSec: TimeInterval) throws -> HTTPRunResult {
            try run(request, timeoutSec)
        }

        static let live = HTTPRunner(run: { request, timeoutSec in
            var request = request
            request.timeoutInterval = timeoutSec

            let semaphore = DispatchSemaphore(value: 0)
            var outData: Data?
            var outResponse: URLResponse?
            var outError: Error?

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                outData = data
                outResponse = response
                outError = error
                semaphore.signal()
            }
            task.resume()

            if semaphore.wait(timeout: .now() + timeoutSec) == .timedOut {
                task.cancel()
                throw URLError(.timedOut)
            }

            if let outError {
                throw outError
            }

            guard let http = outResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key] = String(describing: value)
            }

            return HTTPRunResult(statusCode: http.statusCode, body: outData ?? Data(), headers: headers)
        })
    }

    var homeDirectoryURL: URL
    var processRunner: ProcessRunner
    var httpRunner: HTTPRunner
    var environment: [String: String]

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        processRunner: ProcessRunner = .live,
        httpRunner: HTTPRunner = .live,
        // Defaults to empty so tests stay hermetic; the app passes the real
        // process environment at its single construction site.
        environment: [String: String] = [:]
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.processRunner = processRunner
        self.httpRunner = httpRunner
        self.environment = environment
    }

    func collectTrack1Snapshot(provider: ProviderId, settings: AppSettings) throws -> Track1Snapshot {
        let output: Data

        if provider == .claude, settings.claude.track1Source == .methodB {
            if let oauthUsagePayload = try collectClaudeTrack1OAuthUsageOutput() {
                var payload = oauthUsagePayload

                var resolvedPlan: String? = try collectClaudeTrack1OAuthProfilePlan()
                if resolvedPlan == nil, let executablePath = cliExecutablePath(provider: provider, settings: settings) {
                    let executableURL = URL(fileURLWithPath: executablePath)
                    resolvedPlan = try collectClaudeTrack1FallbackPlan(executableURL: executableURL)
                }

                if let resolvedPlan, let merged = injectingPlanLabel(resolvedPlan, intoMethodBPayloadData: payload) {
                    payload = merged
                }

                output = payload
            } else if let oauthProfilePlan = try collectClaudeTrack1OAuthProfilePlan() {
                guard let payload = makeMethodBCompatiblePayload(plan: oauthProfilePlan, scope: "claude") else {
                    throw CollectionPipelineError.emptyOutput(provider: provider)
                }
                output = payload
            } else {
                let executablePath = cliExecutablePath(provider: provider, settings: settings)
                guard let executablePath else {
                    throw CollectionPipelineError.toolNotFound(provider: provider)
                }

                let executableURL = URL(fileURLWithPath: executablePath)
                if let authStatusFallback = try collectClaudeTrack1FallbackOutput(executableURL: executableURL) {
                    output = authStatusFallback
                } else {
                    throw CollectionPipelineError.commandFailed(provider: provider)
                }
            }
        } else if provider == .codex,
                  let oauthPayload = collectCodexTrack1OAuthRateLimitsOutput() {
            output = oauthPayload
        } else {
            let executablePath = cliExecutablePath(provider: provider, settings: settings)
            guard let executablePath else {
                throw CollectionPipelineError.toolNotFound(provider: provider)
            }

            let executableURL = URL(fileURLWithPath: executablePath)
            do {
                output = try runFirstSuccessfulJSONOutput(provider: provider, executableURL: executableURL)
            } catch {
                if let fallback = try fallbackTrack1MethodBOutput(provider: provider, executableURL: executableURL, after: error) {
                    output = fallback
                } else {
                    throw error
                }
            }
        }

        switch provider {
        case .codex:
            return try CodexTrack1MethodBAdapter.snapshot(from: output)
        case .claude:
            return try ClaudeTrack1Adapter.snapshot(from: output, settings: settings.claude)
        }
    }

    func collectTrack2Points(provider: ProviderId) throws -> [Track2TimelinePoint] {
        switch provider {
        case .codex:
            return try collectCodexTrack2Points()
        case .claude:
            return try collectClaudeTrack2Points()
        }
    }

    /// Charts consume at most 24h of local telemetry; cap retained history so
    /// track2.json cannot grow without bound (a 60MB+ store made every
    /// collection cycle re-encode tens of MB and overrun its timeout).
    /// Anchored to the newest plausible point rather than wall clock so
    /// replayed fixtures and idle periods do not prune valid history.
    private static let track2RetentionInterval: TimeInterval = 30 * 24 * 60 * 60
    /// Corrupt sources can yield far-future timestamps (e.g. millisecond
    /// epochs read as seconds); such points must neither anchor the retention
    /// window — which would prune all real history — nor be kept themselves.
    private static let track2FutureToleranceInterval: TimeInterval = 48 * 60 * 60

    func persistTrack2Points(
        _ points: [Track2TimelinePoint],
        store: Track2Store,
        now: Date = Date()
    ) async throws -> Int {
        guard points.isEmpty == false else {
            return 0
        }

        let existing = try await store.loadAll()
        let merged = deduplicatedTrack2Points(existing + points)
            .sorted(by: { $0.timestamp < $1.timestamp })
        let added = merged.count - existing.count

        let futureCutoff = now.addingTimeInterval(Self.track2FutureToleranceInterval)
        let plausible = merged.filter { $0.timestamp <= futureCutoff }

        let retained: [Track2TimelinePoint]
        if let newest = plausible.last?.timestamp {
            let retentionStart = newest.addingTimeInterval(-Self.track2RetentionInterval)
            retained = plausible.filter { $0.timestamp >= retentionStart }
        } else {
            retained = []
        }

        guard retained != existing else {
            return 0
        }
        try await store.replaceAll(retained)
        // Report at least one change when only pruning rewrote the store, so
        // callers gating display refreshes on this count still update.
        return max(1, added)
    }

    private func cliExecutablePath(provider: ProviderId, settings: AppSettings) -> String? {
        switch provider {
        case .codex:
            return CLIToolDiscovery.discover(toolName: provider.rawValue, overridePath: settings.codex.cliPathOverride).executablePath
        case .claude:
            return CLIToolDiscovery.discover(toolName: provider.rawValue, overridePath: settings.claude.cliPathOverride).executablePath
        }
    }

    private func runFirstSuccessfulJSONOutput(provider: ProviderId, executableURL: URL) throws -> Data {
        let commandCandidates: [[String]]
        switch provider {
        case .codex:
            commandCandidates = [
                ["usage", "--json"],
                ["status", "--json"],
                ["limits", "--json"],
            ]
        case .claude:
            commandCandidates = [
                ["usage", "--json"],
                ["status", "--json"],
                ["account", "--json"],
            ]
        }

        var sawSuccess = false
        for arguments in commandCandidates {
            let runResult = try processRunner.execute(executableURL, arguments)
            guard runResult.status == 0 else {
                continue
            }

            sawSuccess = true
            if runResult.stdout.trimmingTrailingWhitespaceAndNewline().isEmpty == false {
                return runResult.stdout
            }

            if runResult.stderr.trimmingTrailingWhitespaceAndNewline().isEmpty == false {
                return runResult.stderr
            }
        }

        if sawSuccess {
            throw CollectionPipelineError.emptyOutput(provider: provider)
        }
        throw CollectionPipelineError.commandFailed(provider: provider)
    }

    private func fallbackTrack1MethodBOutput(provider: ProviderId, executableURL: URL, after error: Error) throws -> Data? {
        guard shouldAttemptTrack1Fallback(after: error) else {
            return nil
        }

        switch provider {
        case .codex:
            return try collectCodexTrack1FallbackOutput(executableURL: executableURL)
        case .claude:
            return try collectClaudeTrack1FallbackOutput(executableURL: executableURL)
        }
    }

    private func shouldAttemptTrack1Fallback(after error: Error) -> Bool {
        guard let pipelineError = error as? CollectionPipelineError else {
            return false
        }
        switch pipelineError {
        case .commandFailed, .emptyOutput:
            return true
        case .toolNotFound:
            return false
        }
    }

    private func collectClaudeTrack1FallbackOutput(executableURL: URL) throws -> Data? {
        guard let plan = try collectClaudeTrack1FallbackPlan(executableURL: executableURL) else {
            return nil
        }
        return makeMethodBCompatiblePayload(plan: plan, scope: "claude")
    }

    private func collectClaudeTrack1FallbackPlan(executableURL: URL) throws -> String? {
        let result = try processRunner.execute(executableURL, ["auth", "status", "--json"])
        guard result.status == 0 else {
            return nil
        }

        guard let output = firstNonEmptyOutput(stdout: result.stdout, stderr: result.stderr) else {
            return nil
        }

        return extractPlanLabel(
            fromJSONObjectData: output,
            preferredKeys: ["subscriptionType", "subscription_type", "plan", "plan_type", "tier"]
        )
    }

    private func collectClaudeTrack1OAuthUsageOutput(timeoutSec: TimeInterval = 3.0) throws -> Data? {
        let logger = DiagnosticsLogger(provider: .claude)

        if let remaining = Self.claudeOAuthUsageThrottle.remainingCooldown() {
            logger.debug(
                "claude_oauth_usage_cooldown",
                fields: ["remainingSec": .int(Int(remaining.rounded()))]
            )
            return nil
        }

        guard let accessToken = try claudeOAuthAccessToken() else {
            return nil
        }

        guard let usageData = try fetchClaudeOAuthUsage(accessToken: accessToken, timeoutSec: timeoutSec) else {
            return nil
        }

        return makeClaudeOAuthUsageMethodBPayload(fromUsageResponseData: usageData)
    }

    private func collectClaudeTrack1OAuthProfilePlan(timeoutSec: TimeInterval = 3.0) throws -> String? {
        guard let accessToken = try claudeOAuthAccessToken() else {
            return nil
        }

        guard let profileData = try fetchClaudeOAuthProfile(accessToken: accessToken, timeoutSec: timeoutSec) else {
            return nil
        }

        return extractClaudePlanLabelFromOAuthProfileData(profileData)
    }

    private func fetchClaudeOAuthUsage(accessToken: String, timeoutSec: TimeInterval) throws -> Data? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in claudeOAuthHeaders(accessToken: accessToken) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let result = try httpRunner.execute(request, timeoutSec: timeoutSec)
        guard (200...299).contains(result.statusCode) else {
            let logger = DiagnosticsLogger(provider: .claude)
            if result.statusCode == 429 {
                let retryAfter = result.header("Retry-After")
                Self.claudeOAuthUsageThrottle.noteThrottled(retryAfterHeader: retryAfter)
                logger.warning(
                    "claude_oauth_usage_throttled",
                    fields: ["retryAfter": retryAfter.map { .string($0) } ?? .null]
                )
            } else {
                logger.warning(
                    "claude_oauth_usage_failed",
                    fields: ["statusCode": .int(result.statusCode)]
                )
            }
            return nil
        }

        Self.claudeOAuthUsageThrottle.noteSucceeded()

        let trimmed = result.body.trimmingTrailingWhitespaceAndNewline()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fetchClaudeOAuthProfile(accessToken: String, timeoutSec: TimeInterval) throws -> Data? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in claudeOAuthHeaders(accessToken: accessToken) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let result = try httpRunner.execute(request, timeoutSec: timeoutSec)
        guard (200...299).contains(result.statusCode) else {
            return nil
        }

        let trimmed = result.body.trimmingTrailingWhitespaceAndNewline()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func claudeOAuthHeaders(accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.0.37",
        ]
    }

    private func makeClaudeOAuthUsageMethodBPayload(fromUsageResponseData data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        guard let dictionary = json as? [String: Any] else {
            return nil
        }

        var windows: [[String: Any]] = []
        let sortedKeys = dictionary.keys.sorted(by: { $0.lowercased() < $1.lowercased() })

        for key in sortedKeys {
            guard let windowId = claudeOAuthUsageWindowId(forRawWindowKey: key) else {
                continue
            }

            guard let value = dictionary[key], value is NSNull == false else {
                continue
            }

            let usedPercent = extractDoubleValue(
                fromJSONObject: value,
                preferredKeys: [
                    "utilization",
                    "utilisation",
                    "usedPercent",
                    "used_percent",
                    "usedPct",
                    "used_pct",
                    "used",
                ]
            )

            guard let usedPercent else {
                continue
            }

            let used = clampPercent(usedPercent)
            let remaining = clampPercent(100.0 - used)
            let resetAt = extractResetDate(fromJSONObject: value)

            let scope = "claude_\(normalizeKey(key))"
            var window: [String: Any] = [
                "windowId": windowId,
                "scope": scope,
                "rawScopeLabel": scope,
                "usedPercent": used,
                "remainingPercent": remaining,
            ]

            if let resetAt,
               let normalizedResetAt = normalizedResetDate(resetAt, windowSeconds: windowSeconds(forWindowId: windowId)) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                window["resetAt"] = formatter.string(from: normalizedResetAt)
            }

            windows.append(window)
        }

        appendClaudeScopedLimitWindows(from: dictionary, into: &windows)

        guard windows.isEmpty == false else {
            return nil
        }

        let payload: [String: Any] = ["windows": windows]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// Newer usage payloads (July 2026, observed on Max plans) deliver
    /// per-model limits through a `limits` array (kind weekly_scoped with
    /// scope.model) instead of seven_day_<model> top-level keys, which now
    /// arrive as null. Session/weekly entries duplicate the legacy keys and
    /// are only taken when the legacy parse produced nothing for them.
    private func appendClaudeScopedLimitWindows(
        from dictionary: [String: Any],
        into windows: inout [[String: Any]]
    ) {
        guard let limits = dictionary["limits"] as? [[String: Any]] else {
            return
        }

        let existingWindowIds = Set(windows.compactMap { $0["windowId"] as? String })

        for limit in limits {
            guard let rawKind = limit["kind"] as? String else {
                continue
            }

            let windowId: String
            switch normalizeKey(rawKind) {
            case "session":
                windowId = "rolling_5h"
            case "weeklyall":
                windowId = "weekly"
            case "weeklyscoped":
                windowId = "model_specific"
            default:
                continue
            }

            if windowId != "model_specific", existingWindowIds.contains(windowId) {
                continue
            }

            guard let usedPercent = extractDoubleValue(
                fromJSONObject: limit,
                preferredKeys: ["percent", "utilization"]
            ) else {
                continue
            }

            var scopeSuffix = rawKind
            if let scope = limit["scope"] as? [String: Any] {
                let model = scope["model"] as? [String: Any]
                if let name = (model?["display_name"] as? String)
                    ?? (model?["id"] as? String)
                    ?? (scope["surface"] as? String)
                {
                    scopeSuffix += "_\(name)"
                }
            }

            let used = clampPercent(usedPercent)
            let scopeLabel = "claude_\(normalizeKey(scopeSuffix))"
            var window: [String: Any] = [
                "windowId": windowId,
                "scope": scopeLabel,
                "rawScopeLabel": scopeLabel,
                "usedPercent": used,
                "remainingPercent": clampPercent(100.0 - used),
            ]

            if let resetAt = extractResetDate(fromJSONObject: limit),
               let normalizedResetAt = normalizedResetDate(resetAt, windowSeconds: windowSeconds(forWindowId: windowId)) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                window["resetAt"] = formatter.string(from: normalizedResetAt)
            }

            windows.append(window)
        }
    }

    private func injectingPlanLabel(_ plan: String, intoMethodBPayloadData payloadData: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) else {
            return nil
        }
        guard var dictionary = json as? [String: Any] else {
            return nil
        }

        dictionary["plan"] = plan
        return try? JSONSerialization.data(withJSONObject: dictionary)
    }

    private func claudeOAuthUsageWindowId(forRawWindowKey raw: String) -> String? {
        let k = normalizeKey(raw)

        if k == "fivehour" || k.contains("fivehour") {
            return "rolling_5h"
        }

        if k == "sevenday" {
            return "weekly"
        }

        if k.contains("sevenday") {
            return "model_specific"
        }

        return nil
    }

    private func extractClaudePlanLabelFromOAuthProfileData(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let root = json as? [String: Any]

        if let organization = root?["organization"],
           let organizationType = extractStringValue(fromJSONObject: organization, preferredKeys: ["organizationType", "organization_type"]) {
            let normalized = normalizeKey(organizationType)
            if normalized.contains("enterprise") {
                return "enterprise"
            }
            if normalized.contains("business") {
                return "business"
            }
            if normalized.contains("team") {
                return "team"
            }
        }

        if let organizationType = extractStringValue(fromJSONObject: json, preferredKeys: ["organizationType", "organization_type"]) {
            let normalized = normalizeKey(organizationType)
            if normalized.contains("enterprise") {
                return "enterprise"
            }
            if normalized.contains("business") {
                return "business"
            }
            if normalized.contains("team") {
                return "team"
            }
        }

        if let account = root?["account"],
           extractBoolValue(fromJSONObject: account, preferredKeys: ["hasClaudeMax", "has_claude_max"]) == true {
            return "max"
        }

        if let account = root?["account"],
           extractBoolValue(fromJSONObject: account, preferredKeys: ["hasClaudePro", "has_claude_pro"]) == true {
            return "pro"
        }

        if extractBoolValue(fromJSONObject: json, preferredKeys: ["hasClaudeMax", "has_claude_max"]) == true {
            return "max"
        }

        if extractBoolValue(fromJSONObject: json, preferredKeys: ["hasClaudePro", "has_claude_pro"]) == true {
            return "pro"
        }

        return nil
    }

    private func claudeOAuthAccessToken(now: Date = Date()) throws -> String? {
        guard let credentials = try claudeOAuthCredentials(now: now) else {
            return nil
        }

        guard let token = credentials["accessToken"] as? String else {
            return nil
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func claudeOAuthCredentials(now: Date = Date()) throws -> [String: Any]? {
        if let fromFile = try loadClaudeOAuthCredentialsFromFile(now: now) {
            return fromFile
        }

        return try loadClaudeOAuthCredentialsFromKeychain(now: now)
    }

    private func loadClaudeOAuthCredentialsFromFile(now: Date) throws -> [String: Any]? {
        let candidates: [URL] = [
            homeDirectoryURL
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent(".credentials.json"),
            homeDirectoryURL
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("claude", isDirectory: true)
                .appendingPathComponent(".credentials.json"),
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            guard let dict = json as? [String: Any], let nested = dict["claudeAiOauth"] as? [String: Any] else {
                continue
            }
            if isClaudeOAuthTokenExpired(credentials: nested, now: now) {
                continue
            }
            return nested
        }

        return nil
    }

    private func loadClaudeOAuthCredentialsFromKeychain(now: Date) throws -> [String: Any]? {
        let result = try processRunner.execute(
            URL(fileURLWithPath: "/usr/bin/security"),
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
        guard result.status == 0 else {
            return nil
        }

        guard let output = firstNonEmptyOutput(stdout: result.stdout, stderr: result.stderr) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: output) else {
            return nil
        }
        guard let dict = json as? [String: Any], let nested = dict["claudeAiOauth"] as? [String: Any] else {
            return nil
        }

        if isClaudeOAuthTokenExpired(credentials: nested, now: now) {
            return nil
        }

        return nested
    }

    private func isClaudeOAuthTokenExpired(credentials: [String: Any], now: Date) -> Bool {
        guard let accessToken = credentials["accessToken"] as? String,
              accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return true
        }

        guard let expiresAtRaw = credentials["expiresAt"],
              let expiresAtValue = numericDouble(from: expiresAtRaw)
        else {
            return false
        }

        let bufferMs = 5.0 * 60.0 * 1000.0
        let nowMs = now.timeIntervalSince1970 * 1000.0
        return nowMs >= (expiresAtValue - bufferMs)
    }

    private func collectCodexTrack1OAuthRateLimitsOutput(timeoutSec: TimeInterval = 5.0) -> Data? {
        guard let credentials = codexOAuthCredentials() else {
            return nil
        }
        let usageData: Data?
        do {
            usageData = try fetchCodexOAuthUsage(
                accessToken: credentials.accessToken,
                accountId: credentials.accountId,
                timeoutSec: timeoutSec
            )
        } catch {
            return nil
        }
        guard let usageData else {
            return nil
        }
        return makeCodexOAuthUsageMethodBPayload(fromUsageResponseData: usageData)
    }

    private func codexOAuthCredentials() -> (accessToken: String, accountId: String?)? {
        let url = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any]
        else {
            return nil
        }

        let accessToken = (tokens["access_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard accessToken.isEmpty == false else {
            return nil
        }

        let rawAccountId = (tokens["account_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountId = (rawAccountId?.isEmpty ?? true) ? nil : rawAccountId
        return (accessToken, accountId)
    }

    private func fetchCodexOAuthUsage(accessToken: String, accountId: String?, timeoutSec: TimeInterval) throws -> Data? {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("token-meter", forHTTPHeaderField: "User-Agent")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let result = try httpRunner.execute(request, timeoutSec: timeoutSec)
        guard (200...299).contains(result.statusCode) else {
            return nil
        }

        let trimmed = result.body.trimmingTrailingWhitespaceAndNewline()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeCodexOAuthUsageMethodBPayload(fromUsageResponseData data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rateLimit = json["rate_limit"] as? [String: Any] ?? [:]

        var windows: [[String: Any]] = []
        let scopes: [(scopeKey: String, oauthKey: String)] = [
            ("primary", "primary_window"),
            ("secondary", "secondary_window"),
        ]
        for entry in scopes {
            guard let scope = rateLimit[entry.oauthKey] as? [String: Any] else {
                continue
            }
            let usedPercent = extractDoubleValue(fromJSONObject: scope, preferredKeys: ["usedPercent", "used_percent"])
            let resetAt = extractResetDate(fromJSONObject: scope)
            let durationSeconds = extractIntValue(
                fromJSONObject: scope,
                preferredKeys: ["limitWindowSeconds", "limit_window_seconds"]
            )
            let durationMins = durationSeconds.map { Int(Double($0) / 60.0) }

            if usedPercent == nil, resetAt == nil {
                continue
            }

            let windowId = codexWindowId(scopeKey: entry.scopeKey, durationMins: durationMins)
            var window: [String: Any] = [
                "windowId": windowId,
                "scope": "codex_\(entry.scopeKey)",
                "rawScopeLabel": "codex_\(entry.scopeKey)",
            ]

            if let usedPercent {
                let used = clampPercent(usedPercent)
                window["usedPercent"] = used
                window["remainingPercent"] = clampPercent(100.0 - used)
            }

            if let resetAt,
               let normalizedResetAt = normalizedResetDate(
                   resetAt,
                   windowSeconds: durationSeconds.map(TimeInterval.init) ?? windowSeconds(forWindowId: windowId)
               )
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                window["resetAt"] = formatter.string(from: normalizedResetAt)
            }

            windows.append(window)
        }

        guard windows.isEmpty == false else {
            return nil
        }

        var payload: [String: Any] = ["windows": windows]
        if let plan = (json["plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           plan.isEmpty == false
        {
            payload["plan"] = plan
        }
        if let resetCredits = codexResetCreditsAvailable(fromJSONObject: json) {
            payload["resetCreditsAvailable"] = resetCredits
        }

        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func codexResetCreditsAvailable(fromJSONObject object: Any) -> Int? {
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        guard let container = dictionary["rate_limit_reset_credits"]
            ?? dictionary["rateLimitResetCredits"]
        else {
            return nil
        }
        guard let count = extractIntValue(
            fromJSONObject: container,
            preferredKeys: ["availableCount", "available_count"]
        ) else {
            return nil
        }
        return max(0, count)
    }

    private func collectCodexTrack1FallbackOutput(executableURL: URL) throws -> Data? {
        if let appServerPayload = try collectCodexTrack1AppServerRateLimitsOutput(executableURL: executableURL) {
            return appServerPayload
        }

        let authURL = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: authURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let directPlanKeys = [
            "chatgpt_plan_type",
            "chatgptPlanType",
            "subscriptionType",
            "subscription_type",
            "plan",
            "plan_type",
            "tier",
        ]

        let plan = extractStringValue(fromJSONObject: json, preferredKeys: directPlanKeys)
            ?? extractPlanLabelFromJWT(in: json)

        guard let plan else {
            return nil
        }

        return makeMethodBCompatiblePayload(plan: plan, scope: "codex")
    }

    private func collectCodexTrack1AppServerRateLimitsOutput(executableURL: URL) throws -> Data? {
        let requestStream = makeCodexAppServerRateLimitsRequestStream()

        let appServerResult: ProcessRunResult
        if processRunner.mode == .live {
            appServerResult = try runLiveCodexAppServerKeepingStdinOpenBriefly(executableURL: executableURL, stdinData: requestStream)
        } else {
            appServerResult = try processRunner.execute(
                executableURL,
                ["app-server"],
                stdinData: requestStream
            )
        }

        guard appServerResult.status == 0 else {
            return nil
        }

        guard let output = firstNonEmptyOutput(stdout: appServerResult.stdout, stderr: appServerResult.stderr) else {
            return nil
        }

        guard let resultObject = extractCodexRateLimitsResultObject(fromOutputData: output) else {
            return nil
        }

        let rateLimitsObject = codexRateLimitsRootObject(fromResultObject: resultObject)

        let plan = extractStringValue(
            fromJSONObject: rateLimitsObject,
            preferredKeys: ["planType", "plan_type", "plan", "tier"]
        )

        let windows = makeCodexRateLimitMethodBWindows(fromResultObject: rateLimitsObject)
        guard windows.isEmpty == false else {
            return nil
        }

        var payload: [String: Any] = ["windows": windows]
        if let plan {
            payload["plan"] = plan
        }
        // Reset credits can sit beside rateLimits in the result object rather
        // than inside it.
        if let resetCredits = codexResetCreditsAvailable(fromJSONObject: rateLimitsObject)
            ?? codexResetCreditsAvailable(fromJSONObject: resultObject)
        {
            payload["resetCreditsAvailable"] = resetCredits
        }

        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func runLiveCodexAppServerKeepingStdinOpenBriefly(
        executableURL: URL,
        stdinData: Data,
        stdinCloseDelaySec: TimeInterval = 2.0
    ) throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()

        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        try process.run()

        let stdinHandle = stdin.fileHandleForWriting
        stdinHandle.write(stdinData)

        // codex app-server rateLimits response can arrive >1s after requests; keep stdin open >=2s for reliability
        Thread.sleep(forTimeInterval: stdinCloseDelaySec)
        try? stdinHandle.close()

        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData
        )
    }

    private func makeCodexAppServerRateLimitsRequestStream() -> Data {
        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "token-meter",
                        "version": "1.0",
                    ],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "account/rateLimits/read",
                "params": NSNull(),
            ],
        ]

        let lines = messages.compactMap { message -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let text = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return text
        }

        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func extractCodexRateLimitsResultObject(fromOutputData data: Data) -> Any? {
        if let single = try? JSONSerialization.jsonObject(with: data),
           let resultObject = extractCodexRateLimitsResultObject(fromJSONObject: single) {
            return resultObject
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData),
                  let resultObject = extractCodexRateLimitsResultObject(fromJSONObject: json)
            else {
                continue
            }
            return resultObject
        }

        return nil
    }

    private func codexRateLimitsRootObject(fromResultObject object: Any) -> Any {
        guard let dictionary = object as? [String: Any],
              let nested = dictionary["rateLimits"]
        else {
            return object
        }
        return nested
    }

    private func extractCodexRateLimitsResultObject(fromJSONObject object: Any) -> Any? {
        if let dictionary = object as? [String: Any] {
            let methodName = (dictionary["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isRateLimitsResponse =
                methodName == "account/rateLimits/read"
                || (dictionary["id"] as? Int) == 2
                || dictionary["planType"] != nil
                || dictionary["plan_type"] != nil

            if isRateLimitsResponse, let result = dictionary["result"] {
                return result
            }

            if isRateLimitsResponse {
                return dictionary
            }

            for value in dictionary.values {
                if let found = extractCodexRateLimitsResultObject(fromJSONObject: value) {
                    return found
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = extractCodexRateLimitsResultObject(fromJSONObject: value) {
                    return found
                }
            }
        }

        return nil
    }

    private func makeCodexRateLimitMethodBWindows(fromResultObject object: Any) -> [[String: Any]] {
        guard let dictionary = object as? [String: Any] else {
            return []
        }

        var windows: [[String: Any]] = []

        for scopeKey in ["primary", "secondary"] {
            guard let scopeObject = dictionary[scopeKey] else {
                continue
            }

            let usedPercent = extractDoubleValue(fromJSONObject: scopeObject, preferredKeys: ["usedPercent", "used_percent", "usedPct", "used_pct"])
            let remainingPercent = extractDoubleValue(fromJSONObject: scopeObject, preferredKeys: ["remainingPercent", "remaining_percent", "remainingPct", "remaining_pct"])
            let resetAt = extractResetDate(fromJSONObject: scopeObject)
            let durationMins = extractIntValue(fromJSONObject: scopeObject, preferredKeys: ["windowDurationMins", "window_duration_mins", "windowMinutes", "window_minutes"])
                ?? (scopeKey == "primary"
                    ? extractIntValue(fromJSONObject: dictionary, preferredKeys: ["windowDurationMins", "window_duration_mins", "windowMinutes", "window_minutes"])
                    : nil)

            if usedPercent == nil, remainingPercent == nil, resetAt == nil {
                continue
            }

            let used = usedPercent.map(clampPercent)
            let remaining = remainingPercent.map(clampPercent)

            let windowId = codexWindowId(scopeKey: scopeKey, durationMins: durationMins)
            var window: [String: Any] = [
                "windowId": windowId,
                "scope": "codex_\(scopeKey)",
                "rawScopeLabel": "codex_\(scopeKey)",
            ]

            if let used {
                window["usedPercent"] = used
                if remaining == nil {
                    window["remainingPercent"] = clampPercent(100.0 - used)
                }
            }

            if let remaining {
                window["remainingPercent"] = remaining
                if used == nil {
                    window["usedPercent"] = clampPercent(100.0 - remaining)
                }
            }

            if let resetAt,
               let normalizedResetAt = normalizedResetDate(
                   resetAt,
                   windowSeconds: durationMins.map { TimeInterval($0 * 60) } ?? windowSeconds(forWindowId: windowId)
               )
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                window["resetAt"] = formatter.string(from: normalizedResetAt)
            }

            windows.append(window)
        }

        return windows
    }

    private func codexWindowId(scopeKey: String, durationMins: Int?) -> String {
        if let durationMins {
            if durationMins <= 360 {
                return "rolling_5h"
            }
            if durationMins >= 10_000 {
                return "weekly"
            }
        }
        return scopeKey == "secondary" ? "model_specific" : "weekly"
    }

    private func extractDoubleValue(fromJSONObject object: Any, preferredKeys: [String]) -> Double? {
        let normalizedKeys = Set(preferredKeys.map { normalizeKey($0) })
        return extractDoubleValue(fromJSONObject: object, normalizedKeys: normalizedKeys)
    }

    private func extractDoubleValue(fromJSONObject object: Any, normalizedKeys: Set<String>) -> Double? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                guard normalizedKeys.contains(normalizeKey(key)) else { continue }
                if let value = numericDouble(from: value) {
                    return value
                }
            }

            for value in dictionary.values {
                if let found = extractDoubleValue(fromJSONObject: value, normalizedKeys: normalizedKeys) {
                    return found
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = extractDoubleValue(fromJSONObject: value, normalizedKeys: normalizedKeys) {
                    return found
                }
            }
        }

        return nil
    }

    private func extractIntValue(fromJSONObject object: Any, preferredKeys: [String]) -> Int? {
        extractDoubleValue(fromJSONObject: object, preferredKeys: preferredKeys).map { Int($0.rounded()) }
    }

    /// Keep only plausible "next reset" values. A healthy API reports a
    /// future timestamp within roughly one window (~1.33 windows observed on
    /// the Codex weekly window, so allow 1.5). A past value means the data is
    /// stale (e.g. collected before an auth expiry) and a far-future value is
    /// garbage; drop both rather than display them.
    func normalizedResetDate(_ resetAt: Date, windowSeconds: TimeInterval?, now: Date = Date()) -> Date? {
        guard resetAt > now else {
            return nil
        }
        guard let windowSeconds, windowSeconds > 0 else {
            return resetAt
        }
        return resetAt.timeIntervalSince(now) <= windowSeconds * 1.5 ? resetAt : nil
    }

    private func windowSeconds(forWindowId windowId: String) -> TimeInterval? {
        switch windowId {
        case "rolling_5h":
            return 5 * 60 * 60
        case "weekly", "model_specific":
            return 7 * 24 * 60 * 60
        default:
            return nil
        }
    }

    private func extractResetDate(fromJSONObject object: Any) -> Date? {
        let raw = extractAnyValue(fromJSONObject: object, preferredKeys: ["resetAt", "reset_at", "resetsAt", "resets_at", "resetTs", "reset_ts"])
        guard let raw else {
            return nil
        }

        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            if let asNumber = Double(trimmed) {
                return dateFromEpochSecondsOrMillis(asNumber)
            }
            let formatterWithFraction = ISO8601DateFormatter()
            formatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatterWithFraction.date(from: trimmed) {
                return parsed
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: trimmed)
        }

        if let numeric = numericDouble(from: raw) {
            return dateFromEpochSecondsOrMillis(numeric)
        }

        return nil
    }

    private func extractAnyValue(fromJSONObject object: Any, preferredKeys: [String]) -> Any? {
        let normalizedKeys = Set(preferredKeys.map { normalizeKey($0) })
        return extractAnyValue(fromJSONObject: object, normalizedKeys: normalizedKeys)
    }

    private func extractAnyValue(fromJSONObject object: Any, normalizedKeys: Set<String>) -> Any? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if normalizedKeys.contains(normalizeKey(key)) {
                    return value
                }
            }
            for value in dictionary.values {
                if let found = extractAnyValue(fromJSONObject: value, normalizedKeys: normalizedKeys) {
                    return found
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = extractAnyValue(fromJSONObject: value, normalizedKeys: normalizedKeys) {
                    return found
                }
            }
        }

        return nil
    }

    private func numericDouble(from value: Any) -> Double? {
        if let d = value as? Double {
            return d
        }
        if let i = value as? Int {
            return Double(i)
        }
        if let i64 = value as? Int64 {
            return Double(i64)
        }
        if let n = value as? NSNumber {
            return n.doubleValue
        }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(trimmed)
        }
        return nil
    }

    private func extractBoolValue(fromJSONObject object: Any, preferredKeys: [String]) -> Bool? {
        let normalizedKeys = Set(preferredKeys.map { normalizeKey($0) })
        return extractBoolValue(fromJSONObject: object, normalizedKeys: normalizedKeys)
    }

    private func extractBoolValue(fromJSONObject object: Any, normalizedKeys: Set<String>) -> Bool? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                guard normalizedKeys.contains(normalizeKey(key)) else { continue }
                if let b = value as? Bool {
                    return b
                }
                if let n = value as? NSNumber {
                    return n.boolValue
                }
                if let s = value as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if trimmed == "true" || trimmed == "yes" || trimmed == "1" { return true }
                    if trimmed == "false" || trimmed == "no" || trimmed == "0" { return false }
                }
            }

            for value in dictionary.values {
                if let found = extractBoolValue(fromJSONObject: value, normalizedKeys: normalizedKeys) {
                    return found
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = extractBoolValue(fromJSONObject: value, normalizedKeys: normalizedKeys) {
                    return found
                }
            }
        }

        return nil
    }

    private func dateFromEpochSecondsOrMillis(_ value: Double) -> Date {
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000.0)
        }
        return Date(timeIntervalSince1970: value)
    }

    private func clampPercent(_ value: Double) -> Double {
        min(100.0, max(0.0, value))
    }

    private func firstNonEmptyOutput(stdout: Data, stderr: Data) -> Data? {
        let trimmedStdout = stdout.trimmingTrailingWhitespaceAndNewline()
        if trimmedStdout.isEmpty == false {
            return trimmedStdout
        }

        let trimmedStderr = stderr.trimmingTrailingWhitespaceAndNewline()
        if trimmedStderr.isEmpty == false {
            return trimmedStderr
        }

        return nil
    }

    private func makeMethodBCompatiblePayload(plan: String, scope: String) -> Data? {
        let payload: [String: Any] = [
            "plan": plan,
            "windows": [
                [
                    "windowId": "weekly",
                    "scope": scope,
                ],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func extractPlanLabel(fromJSONObjectData data: Data, preferredKeys: [String]) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return extractStringValue(fromJSONObject: json, preferredKeys: preferredKeys)
    }

    private func extractStringValue(fromJSONObject object: Any, preferredKeys: [String]) -> String? {
        let normalizedKeys = Set(preferredKeys.map { normalizeKey($0) })
        return extractStringValue(fromJSONObject: object, normalizedKeys: normalizedKeys)
    }

    private func extractStringValue(fromJSONObject object: Any, normalizedKeys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                guard normalizedKeys.contains(normalizeKey(key)) else { continue }
                if let string = value as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty == false {
                        return trimmed
                    }
                }
            }

            for value in dictionary.values {
                if let found = extractStringValue(fromJSONObject: value, normalizedKeys: normalizedKeys) {
                    return found
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = extractStringValue(fromJSONObject: value, normalizedKeys: normalizedKeys) {
                    return found
                }
            }
        }

        return nil
    }

    private func extractPlanLabelFromJWT(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let found = extractPlanLabelFromJWT(in: value) {
                    return found
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = extractPlanLabelFromJWT(in: value) {
                    return found
                }
            }
            return nil
        }

        guard let text = object as? String,
              let token = jwtCandidate(from: text)
        else {
            return nil
        }

        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let payloadData = decodeBase64URL(String(segments[1])),
              let payloadJSON = try? JSONSerialization.jsonObject(with: payloadData)
        else {
            return nil
        }

        return extractStringValue(
            fromJSONObject: payloadJSON,
            preferredKeys: ["chatgpt_plan_type", "chatgptPlanType", "subscriptionType", "subscription_type", "plan", "plan_type", "tier"]
        )
    }

    private func jwtCandidate(from value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        if trimmed.lowercased().hasPrefix("bearer ") {
            trimmed = String(trimmed.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard trimmed.split(separator: ".", omittingEmptySubsequences: false).count >= 2 else {
            return nil
        }
        return trimmed
    }

    private func decodeBase64URL(_ encoded: String) -> Data? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: base64)
    }

    private func normalizeKey(_ key: String) -> String {
        key
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func collectCodexTrack2Points() throws -> [Track2TimelinePoint] {
        let codexRoot = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)

        let primaryFiles = recursiveFiles(
            at: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            where: { $0.pathExtension.lowercased() == "jsonl" }
        )

        let primaryPoints = collectIncrementalTrack2Points(
            from: primaryFiles,
            provider: .codex,
            source: .codexPrimary,
            parser: { data, sourceFile, initialModel in
                let output = CodexTrack2PrimaryParser.timelinePoints(
                    from: data,
                    sourceFile: sourceFile,
                    initialModel: initialModel
                )
                return Track2ParseResult(points: output.points, lastKnownModel: output.lastKnownModel)
            }
        )
        let openCodePoints = try collectOpenCodeTrack2Points(provider: .codex)
        let piPoints = collectPiTrack2Points(provider: .codex)
        return deduplicatedTrack2Points(primaryPoints + openCodePoints + piPoints).sorted(by: { $0.timestamp < $1.timestamp })
    }

    private func collectClaudeTrack2Points() throws -> [Track2TimelinePoint] {
        let secondaryRoots = [
            homeDirectoryURL.appendingPathComponent(".claude/projects", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]

        var secondaryFiles: [URL] = []
        for root in secondaryRoots {
            secondaryFiles += recursiveFiles(at: root, where: { $0.pathExtension.lowercased() == "jsonl" })
        }

        var points: [Track2TimelinePoint] = collectIncrementalTrack2Points(
            from: secondaryFiles,
            provider: .claude,
            source: .claudeSecondary,
            parser: { data, sourceFile, _ in
                Track2ParseResult(
                    points: ClaudeTrack2SecondaryParser.timelinePoints(from: data, sourceFile: sourceFile),
                    lastKnownModel: nil
                )
            }
        )

        points += try collectOpenCodeTrack2Points(provider: .claude)
        points += collectPiTrack2Points(provider: .claude)

        return deduplicatedTrack2Points(points).sorted(by: { $0.timestamp < $1.timestamp })
    }

    /// pi keeps one JSONL file per session under
    /// `~/.pi/agent/sessions/--<encoded cwd>--/`. Turns are routed to the
    /// provider that owns the model, so this runs once per provider and each
    /// pass keeps only its own share. Both passes scan the same files, and so
    /// do the Codex and Claude passes for their own logs, which is why the
    /// cursors are scoped by source as well as by provider.
    private func collectPiTrack2Points(provider: ProviderId) -> [Track2TimelinePoint] {
        let sessionFiles = recursiveFiles(
            at: piSessionsRootURL(),
            where: { $0.pathExtension.lowercased() == "jsonl" }
        )
        // Headers sit at the head of the file, which an incremental pass has
        // long scrolled past, so they are read separately — but only for files
        // that actually have new bytes, since the parser is not called for the
        // ones the cursor skips.
        var headersByPath: [String: PiTrack2Parser.SessionHeader] = [:]

        // An empty file list is passed through rather than short-circuited, so
        // that cursors for sessions the user deleted are evicted.
        return collectIncrementalTrack2Points(
            from: sessionFiles,
            provider: provider,
            source: .piSession,
            parser: { data, sourceFile, _ in
                let header: PiTrack2Parser.SessionHeader
                if let cachedHeader = headersByPath[sourceFile] {
                    header = cachedHeader
                } else {
                    header = piSessionHeader(at: URL(fileURLWithPath: sourceFile))
                    headersByPath[sourceFile] = header
                }

                return Track2ParseResult(
                    points: PiTrack2Parser.timelinePoints(
                        from: data,
                        sourceFile: sourceFile,
                        provider: provider,
                        header: header
                    ),
                    lastKnownModel: nil
                )
            }
        )
    }

    /// Mirrors pi's own resolution order (`PI_CODING_AGENT_SESSION_DIR`, then
    /// `PI_CODING_AGENT_DIR`, then `~/.pi/agent`). A GUI launch does not
    /// inherit a shell's exports, so the overrides only apply when TokenMeter
    /// itself was started with them.
    private func piSessionsRootURL() -> URL {
        if let sessionDir = expandedPiPath(environment["PI_CODING_AGENT_SESSION_DIR"]) {
            return sessionDir
        }

        let agentRoot = expandedPiPath(environment["PI_CODING_AGENT_DIR"])
            ?? homeDirectoryURL
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)

        return agentRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    private func expandedPiPath(_ rawPath: String?) -> URL? {
        guard let rawPath else {
            return nil
        }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        if trimmed == "~" {
            return homeDirectoryURL
        }
        if trimmed.hasPrefix("~/") {
            return homeDirectoryURL.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Reads the `{"type":"session",...}` line that opens a session file. The
    /// header's creation time is what separates turns the session actually
    /// spent from history `/fork` and `/clone` copied in verbatim; its id is
    /// the session identity for every point in the file.
    private func piSessionHeader(at fileURL: URL) -> PiTrack2Parser.SessionHeader {
        let fallbackSessionId = piSessionIdFromFileName(fileURL)

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return PiTrack2Parser.SessionHeader(sessionId: fallbackSessionId)
        }
        defer {
            try? handle.close()
        }

        // Cut at the newline before decoding: the probe runs past the header
        // into message text, and slicing a multi-byte character in half there
        // would fail the whole decode.
        guard let head = try? handle.read(upToCount: Self.piSessionHeaderProbeBytes) else {
            return PiTrack2Parser.SessionHeader(sessionId: fallbackSessionId)
        }
        let firstLineData = head.firstIndex(of: 0x0A).map { Data(head[..<$0]) } ?? head

        guard let firstLine = String(data: firstLineData, encoding: .utf8),
              let header = PiTrack2Parser.sessionHeader(fromFirstLine: firstLine)
        else {
            return PiTrack2Parser.SessionHeader(sessionId: fallbackSessionId)
        }

        return PiTrack2Parser.SessionHeader(
            sessionId: header.sessionId ?? fallbackSessionId,
            startedAt: header.startedAt
        )
    }

    /// Session files are named `<timestamp>_<session-id>.jsonl`.
    private func piSessionIdFromFileName(_ fileURL: URL) -> String? {
        let name = fileURL.deletingPathExtension().lastPathComponent
        guard let separatorIndex = name.firstIndex(of: "_") else {
            return name.isEmpty ? nil : name
        }
        let sessionId = String(name[name.index(after: separatorIndex)...])
        return sessionId.isEmpty ? nil : sessionId
    }

    private func collectOpenCodeTrack2Points(provider: ProviderId) throws -> [Track2TimelinePoint] {
        let dbURL = homeDirectoryURL
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")

        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return []
        }

        let homeKey = track2StateHomeKey()
        let lastSeenRowID = Self.track2IncrementalState.openCodeCursor(homeKey: homeKey, provider: provider)
        let rows = try queryOpenCodeAssistantRows(from: dbURL, afterRowID: lastSeenRowID)

        var points: [Track2TimelinePoint] = []
        points.reserveCapacity(rows.count)
        var maxScannedRowID = lastSeenRowID

        for row in rows {
            if row.rowID > maxScannedRowID {
                maxScannedRowID = row.rowID
            }
            guard let point = openCodeTrack2Point(from: row, provider: provider) else {
                continue
            }
            points.append(point)
        }

        if maxScannedRowID > lastSeenRowID {
            Self.track2IncrementalState.setOpenCodeCursor(maxScannedRowID, homeKey: homeKey, provider: provider)
        }

        return points
    }

    private func queryOpenCodeAssistantRows(from dbURL: URL, afterRowID: Int64) throws -> [OpenCodeAssistantRow] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return []
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            if database != nil {
                sqlite3_close(database)
            }
            return []
        }
        defer {
            sqlite3_close(database)
        }

        let sql = """
        SELECT
          rowid,
          COALESCE(json_extract(data, '$.id'), id),
          COALESCE(json_extract(data, '$.sessionID'), json_extract(data, '$.sessionId'), session_id),
          COALESCE(json_extract(data, '$.modelID'), json_extract(data, '$.model.modelID')),
          COALESCE(json_extract(data, '$.providerID'), json_extract(data, '$.model.providerID')),
          COALESCE(json_extract(data, '$.time.completed'), json_extract(data, '$.time.created'), time_created),
          json_extract(data, '$.tokens.input'),
          json_extract(data, '$.tokens.output')
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant' AND rowid > ?
        ORDER BY rowid ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return []
        }
        guard sqlite3_bind_int64(statement, 1, afterRowID) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer {
            sqlite3_finalize(statement)
        }

        var rows: [OpenCodeAssistantRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                OpenCodeAssistantRow(
                    rowID: sqlite3_column_int64(statement, 0),
                    messageId: normalizedSQLiteText(sqliteColumnText(statement, index: 1)),
                    sessionId: normalizedSQLiteText(sqliteColumnText(statement, index: 2)),
                    modelId: normalizedSQLiteText(sqliteColumnText(statement, index: 3)),
                    providerId: normalizedSQLiteText(sqliteColumnText(statement, index: 4)),
                    timestamp: sqliteColumnDouble(statement, index: 5),
                    inputTokens: sqliteColumnInt(statement, index: 6),
                    outputTokens: sqliteColumnInt(statement, index: 7)
                )
            )
        }

        return rows
    }

    struct Track2ParseResult {
        var points: [Track2TimelinePoint]
        var lastKnownModel: String?
    }

    private func collectIncrementalTrack2Points(
        from files: [URL],
        provider: ProviderId,
        source: Track2CursorSource,
        parser: (Data, String, String?) -> Track2ParseResult
    ) -> [Track2TimelinePoint] {
        let homeKey = track2StateHomeKey()
        let scope = Track2CursorScope(provider: provider, source: source)
        let currentCursors = Self.track2IncrementalState.fileCursors(homeKey: homeKey, scope: scope)
        var updatedCursors = currentCursors
        var points: [Track2TimelinePoint] = []

        for fileURL in files {
            let filePath = fileURL.path
            guard let metadata = track2FileMetadata(for: fileURL) else {
                continue
            }

            let previousCursor = currentCursors[filePath]
            var readOffset: Int64 = 0
            var parsePrefix = Data()
            let initialModel = previousCursor?.lastKnownModel

            if let previousCursor {
                if previousCursor.matchesIdentity(with: metadata) == false || metadata.fileSize < previousCursor.offset {
                    readOffset = 0
                } else if metadata.fileSize == previousCursor.offset {
                    if metadata.modifiedAt == previousCursor.modifiedAt {
                        updatedCursors[filePath] = previousCursor
                        continue
                    }
                    readOffset = 0
                } else {
                    readOffset = previousCursor.offset
                    parsePrefix.reserveCapacity(previousCursor.contextTail.count + previousCursor.pendingTail.count)
                    parsePrefix.append(previousCursor.contextTail)
                    parsePrefix.append(previousCursor.pendingTail)
                }
            }

            guard let deltaData = readTrack2FileData(fileURL, fromOffset: readOffset) else {
                continue
            }

            var parseBuffer = parsePrefix
            parseBuffer.append(deltaData)

            let split = splitCompleteJSONLData(parseBuffer)
            let parseData: Data
            var pendingTail = split.pending
            if readOffset == 0 {
                parseData = parseBuffer
                if pendingTail.isEmpty == false,
                   parser(pendingTail, filePath, initialModel).points.isEmpty == false
                {
                    pendingTail = Data()
                }
            } else if split.complete.count > parsePrefix.count {
                parseData = split.complete
            } else {
                parseData = Data()
            }

            var lastKnownModel = initialModel
            if parseData.isEmpty == false {
                let parsed = parser(parseData, filePath, initialModel)
                points += parsed.points
                if parsed.lastKnownModel != nil {
                    lastKnownModel = parsed.lastKnownModel
                }
            }

            // A trailing fragment carried in `pendingTail` is replayed as a
            // prefix on the next cycle, so it must not also end the context
            // tail: the full-read path parses the whole buffer, fragment
            // included, and storing it in both places would glue it to itself
            // and corrupt the line once the writer completes it.
            let contextSource: Data
            if parseData.isEmpty {
                contextSource = previousCursor?.contextTail ?? Data()
            } else {
                contextSource = pendingTail.isEmpty ? parseData : split.complete
            }
            let contextTail = trimmedTrack2ContextTail(contextSource)

            updatedCursors[filePath] = Track2FileCursor(
                inode: metadata.inode,
                modifiedAt: metadata.modifiedAt,
                fileSize: metadata.fileSize,
                offset: metadata.fileSize,
                pendingTail: pendingTail,
                contextTail: contextTail,
                lastKnownModel: lastKnownModel
            )
        }

        let activePaths = Set(files.map(\.path))
        updatedCursors = updatedCursors.filter { activePaths.contains($0.key) }
        Self.track2IncrementalState.setFileCursors(updatedCursors, homeKey: homeKey, scope: scope)

        return points
    }

    private func track2FileMetadata(for fileURL: URL) -> Track2FileMetadata? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modificationDate = values.contentModificationDate,
              let fileSize = values.fileSize
        else {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value

        return Track2FileMetadata(
            inode: inode,
            modifiedAt: modificationDate.timeIntervalSince1970,
            fileSize: Int64(fileSize)
        )
    }

    private func readTrack2FileData(_ fileURL: URL, fromOffset offset: Int64) -> Data? {
        guard offset >= 0, let safeOffset = UInt64(exactly: offset) else {
            return nil
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: safeOffset)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    private func splitCompleteJSONLData(_ data: Data) -> (complete: Data, pending: Data) {
        guard let lastLineFeedIndex = data.lastIndex(of: 0x0A) else {
            return (Data(), data)
        }

        let splitIndex = data.index(after: lastLineFeedIndex)
        return (Data(data[..<splitIndex]), Data(data[splitIndex...]))
    }

    private func trimmedTrack2ContextTail(_ data: Data) -> Data {
        guard data.count > Self.track2ContextTailBytes else {
            return data
        }
        let start = data.index(data.endIndex, offsetBy: -Self.track2ContextTailBytes)
        return Data(data[start...])
    }

    private func track2StateHomeKey() -> String {
        homeDirectoryURL.standardizedFileURL.path
    }

    private func openCodeTrack2Point(from row: OpenCodeAssistantRow, provider: ProviderId) -> Track2TimelinePoint? {
        guard let model = row.modelId, model.isEmpty == false else {
            return nil
        }

        let modelLower = model.lowercased()
        let mappedProvider: ProviderId
        if modelLower.contains("codex") || modelLower.contains("gpt") {
            mappedProvider = .codex
        } else if modelLower.contains("claude") {
            mappedProvider = .claude
        } else {
            let providerHint = row.providerId?.lowercased()
            if providerHint == "anthropic" {
                mappedProvider = .claude
            } else if providerHint == "openai" {
                mappedProvider = .codex
            } else {
                return nil
            }
        }

        guard mappedProvider == provider else {
            return nil
        }

        guard let timestamp = row.timestamp else {
            return nil
        }

        let epochSeconds = timestamp > 10_000_000_000 ? timestamp / 1000.0 : timestamp
        let input = row.inputTokens
        let output = row.outputTokens
        let tokenTotal = (input ?? 0) + (output ?? 0)
        guard tokenTotal > 0 else {
            return nil
        }

        let sessionId = row.sessionId
        let totalTokens = (input != nil || output != nil) ? tokenTotal : nil

        let confidence: TrackConfidence
        if sessionId != nil,
           input != nil,
           output != nil,
           totalTokens != nil
        {
            confidence = .medium
        } else {
            confidence = .low
        }

        return Track2TimelinePoint(
            provider: provider,
            timestamp: Date(timeIntervalSince1970: epochSeconds),
            sessionId: sessionId,
            model: model,
            promptTokens: input,
            completionTokens: output,
            totalTokens: totalTokens,
            sourceFile: "opencode_db:\(row.messageId ?? "unknown")",
            confidence: confidence,
            parserVersion: Self.openCodeTrack2ParserVersion
        )
    }

    private func normalizedSQLiteText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.lowercased() != "null" else {
            return nil
        }
        return trimmed
    }

    private func sqliteColumnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index)
        else {
            return nil
        }
        return String(cString: cString)
    }

    private func sqliteColumnDouble(_ statement: OpaquePointer, index: Int32) -> Double? {
        let columnType = sqlite3_column_type(statement, index)
        switch columnType {
        case SQLITE_INTEGER, SQLITE_FLOAT:
            return sqlite3_column_double(statement, index)
        case SQLITE_TEXT:
            guard let text = sqliteColumnText(statement, index: index) else { return nil }
            return Double(text)
        default:
            return nil
        }
    }

    private func sqliteColumnInt(_ statement: OpaquePointer, index: Int32) -> Int? {
        let columnType = sqlite3_column_type(statement, index)
        switch columnType {
        case SQLITE_INTEGER, SQLITE_FLOAT:
            return Int(sqlite3_column_int64(statement, index))
        case SQLITE_TEXT:
            guard let text = sqliteColumnText(statement, index: index) else { return nil }
            if let intValue = Int(text) {
                return intValue
            }
            if let doubleValue = Double(text) {
                return Int(doubleValue)
            }
            return nil
        default:
            return nil
        }
    }

    private struct OpenCodeAssistantRow {
        var rowID: Int64
        var messageId: String?
        var sessionId: String?
        var modelId: String?
        var providerId: String?
        var timestamp: Double?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    private struct Track2FileMetadata {
        var inode: UInt64?
        var modifiedAt: TimeInterval
        var fileSize: Int64
    }

    private struct Track2FileCursor {
        var inode: UInt64?
        var modifiedAt: TimeInterval
        var fileSize: Int64
        var offset: Int64
        var pendingTail: Data
        var contextTail: Data
        // Carries forward the last model observed in this file so that
        // incremental cycles after the file head has scrolled past the
        // 64KB context tail can still tag token events with a model.
        var lastKnownModel: String?

        func matchesIdentity(with metadata: Track2FileMetadata) -> Bool {
            if let inode, let metadataInode = metadata.inode {
                return inode == metadataInode
            }
            return true
        }
    }

    /// Distinguishes the telemetry sources that share a provider. Cursor
    /// eviction drops every path a call did not scan, so two sources writing
    /// the same scope would wipe each other's cursors on every cycle and force
    /// both to re-read their files from the start forever.
    private enum Track2CursorSource: String {
        case codexPrimary
        case claudeSecondary
        case piSession
    }

    private struct Track2CursorScope: Hashable {
        var provider: ProviderId
        var source: Track2CursorSource
    }

    private final class Track2IncrementalState: @unchecked Sendable {
        private let lock = NSLock()
        private var fileCursorsByHome: [String: [Track2CursorScope: [String: Track2FileCursor]]] = [:]
        private var openCodeCursorByHome: [String: [ProviderId: Int64]] = [:]

        func fileCursors(homeKey: String, scope: Track2CursorScope) -> [String: Track2FileCursor] {
            lock.lock()
            let cursors = fileCursorsByHome[homeKey]?[scope] ?? [:]
            lock.unlock()
            return cursors
        }

        func setFileCursors(_ cursors: [String: Track2FileCursor], homeKey: String, scope: Track2CursorScope) {
            lock.lock()
            var scopedCursors = fileCursorsByHome[homeKey] ?? [:]
            scopedCursors[scope] = cursors
            fileCursorsByHome[homeKey] = scopedCursors
            lock.unlock()
        }

        func openCodeCursor(homeKey: String, provider: ProviderId) -> Int64 {
            lock.lock()
            let cursor = openCodeCursorByHome[homeKey]?[provider] ?? 0
            lock.unlock()
            return cursor
        }

        func setOpenCodeCursor(_ cursor: Int64, homeKey: String, provider: ProviderId) {
            lock.lock()
            var providerCursors = openCodeCursorByHome[homeKey] ?? [:]
            providerCursors[provider] = cursor
            openCodeCursorByHome[homeKey] = providerCursors
            lock.unlock()
        }
    }

    private func recursiveFiles(at root: URL, where shouldInclude: (URL) -> Bool) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard shouldInclude(fileURL) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                continue
            }
            files.append(fileURL)
        }

        return files.sorted(by: { $0.path < $1.path })
    }

    private func deduplicatedTrack2Points(_ points: [Track2TimelinePoint]) -> [Track2TimelinePoint] {
        var seen: Set<String> = []
        var deduped: [Track2TimelinePoint] = []
        deduped.reserveCapacity(points.count)

        for point in points {
            let key = dedupKey(for: point)
            if seen.insert(key).inserted {
                deduped.append(point)
            }
        }

        return deduped
    }

    private func dedupKey(for point: Track2TimelinePoint) -> String {
        let ts = Int64((point.timestamp.timeIntervalSince1970 * 1000.0).rounded())
        let session = (point.sessionId ?? "").lowercased()
        let model = (point.model ?? "").lowercased()
        let prompt = point.promptTokens.map(String.init) ?? "-"
        let completion = point.completionTokens.map(String.init) ?? "-"
        let total = point.totalTokens.map(String.init) ?? "-"
        return "\(point.provider.rawValue)|\(ts)|\(session)|\(model)|\(prompt)|\(completion)|\(total)"
    }
}

private extension Data {
    func trimmingTrailingWhitespaceAndNewline() -> Data {
        guard let text = String(data: self, encoding: .utf8) else {
            return self
        }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}
