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
    private let collector = ProviderCollectionRuntime()

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
                    periodNs: periodNs,
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

struct ProviderCollectionRuntime: Sendable {
    private static let openCodeTrack2ParserVersion = "opencode_track2_message_v1"
    private static let track2ContextTailBytes = 64 * 1024
    private static let track2IncrementalState = Track2IncrementalState()

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

            return HTTPRunResult(statusCode: http.statusCode, body: outData ?? Data())
        })
    }

    var homeDirectoryURL: URL
    var processRunner: ProcessRunner
    var httpRunner: HTTPRunner

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        processRunner: ProcessRunner = .live,
        httpRunner: HTTPRunner = .live
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.processRunner = processRunner
        self.httpRunner = httpRunner
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

    func persistTrack2Points(_ points: [Track2TimelinePoint], store: Track2Store) async throws -> Int {
        guard points.isEmpty == false else {
            return 0
        }

        let existing = try await store.loadAll()
        let merged = deduplicatedTrack2Points(existing + points)
            .sorted(by: { $0.timestamp < $1.timestamp })

        if merged != existing {
            try await store.replaceAll(merged)
            return merged.count - existing.count
        }

        return 0
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
            return nil
        }

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

            if let resetAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                window["resetAt"] = formatter.string(from: resetAt)
            }

            windows.append(window)
        }

        guard windows.isEmpty == false else {
            return nil
        }

        let payload: [String: Any] = ["windows": windows]
        return try? JSONSerialization.data(withJSONObject: payload)
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

            var window: [String: Any] = [
                "windowId": codexWindowId(scopeKey: scopeKey, durationMins: durationMins),
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

            if let resetAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                window["resetAt"] = formatter.string(from: resetAt)
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
            parser: { data, sourceFile in
                CodexTrack2PrimaryParser.timelinePoints(from: data, sourceFile: sourceFile)
            }
        )
        let openCodePoints = try collectOpenCodeTrack2Points(provider: .codex)
        return deduplicatedTrack2Points(primaryPoints + openCodePoints).sorted(by: { $0.timestamp < $1.timestamp })
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
            parser: { data, sourceFile in
                ClaudeTrack2SecondaryParser.timelinePoints(from: data, sourceFile: sourceFile)
            }
        )

        points += try collectOpenCodeTrack2Points(provider: .claude)

        return deduplicatedTrack2Points(points).sorted(by: { $0.timestamp < $1.timestamp })
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

    private func collectIncrementalTrack2Points(
        from files: [URL],
        provider: ProviderId,
        parser: (Data, String) -> [Track2TimelinePoint]
    ) -> [Track2TimelinePoint] {
        let homeKey = track2StateHomeKey()
        let currentCursors = Self.track2IncrementalState.fileCursors(homeKey: homeKey, provider: provider)
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
                   parser(pendingTail, filePath).isEmpty == false
                {
                    pendingTail = Data()
                }
            } else if split.complete.count > parsePrefix.count {
                parseData = split.complete
            } else {
                parseData = Data()
            }

            if parseData.isEmpty == false {
                points += parser(parseData, filePath)
            }

            let contextSource = parseData.isEmpty ? (previousCursor?.contextTail ?? Data()) : parseData
            let contextTail = trimmedTrack2ContextTail(contextSource)

            updatedCursors[filePath] = Track2FileCursor(
                inode: metadata.inode,
                modifiedAt: metadata.modifiedAt,
                fileSize: metadata.fileSize,
                offset: metadata.fileSize,
                pendingTail: pendingTail,
                contextTail: contextTail
            )
        }

        let activePaths = Set(files.map(\.path))
        updatedCursors = updatedCursors.filter { activePaths.contains($0.key) }
        Self.track2IncrementalState.setFileCursors(updatedCursors, homeKey: homeKey, provider: provider)

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
        if modelLower.contains("codex") {
            mappedProvider = .codex
        } else if modelLower.contains("claude") {
            mappedProvider = .claude
        } else {
            let providerHint = row.providerId?.lowercased()
            if providerHint == "anthropic" {
                mappedProvider = .claude
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

        func matchesIdentity(with metadata: Track2FileMetadata) -> Bool {
            if let inode, let metadataInode = metadata.inode {
                return inode == metadataInode
            }
            return true
        }
    }

    private final class Track2IncrementalState: @unchecked Sendable {
        private let lock = NSLock()
        private var fileCursorsByHome: [String: [ProviderId: [String: Track2FileCursor]]] = [:]
        private var openCodeCursorByHome: [String: [ProviderId: Int64]] = [:]

        func fileCursors(homeKey: String, provider: ProviderId) -> [String: Track2FileCursor] {
            lock.lock()
            let cursors = fileCursorsByHome[homeKey]?[provider] ?? [:]
            lock.unlock()
            return cursors
        }

        func setFileCursors(_ cursors: [String: Track2FileCursor], homeKey: String, provider: ProviderId) {
            lock.lock()
            var providerCursors = fileCursorsByHome[homeKey] ?? [:]
            providerCursors[provider] = cursors
            fileCursorsByHome[homeKey] = providerCursors
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
