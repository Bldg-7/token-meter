import Foundation
import Dispatch

enum CLIToolProbeState: String, Codable, Equatable {
    case found
    case missing
    case invalid
}

enum CLIToolPathSource: String, Codable, Equatable {
    case manualOverride
    case path
    case fallbackDirectory
}

enum CLIToolProbeReasonCode: String, Codable, Equatable {
    case overrideNotFound
    case overrideIsDirectory
    case overrideNotExecutable

    case notFound

    case versionLaunchFailed
    case versionTimedOut
    case versionOutputEmpty
    case versionParseFailed
}

struct CLIToolDiscoveryResult: Codable, Equatable {
    var toolName: String
    var state: CLIToolProbeState
    var executablePath: String?
    var source: CLIToolPathSource?
    var reasonCode: CLIToolProbeReasonCode?
}

struct CLIToolVersionProbeResult: Codable, Equatable {
    var state: CLIToolProbeState
    var version: String?
    var reasonCode: CLIToolProbeReasonCode?
}

struct CLIToolHealthProbeResult: Codable, Equatable {
    var state: CLIToolProbeState
    var discovery: CLIToolDiscoveryResult
    var version: CLIToolVersionProbeResult
}

struct CLIToolDiscovery {
    static func findExecutable(named name: String, searchPaths: [URL]? = nil) -> URL? {
        let candidates = searchPaths ?? defaultSearchPaths()
        for dir in candidates {
            let url = dir.appendingPathComponent(name)
            if isExecutableFile(url) {
                return url
            }
        }
        return nil
    }

    static func discover(
        toolName: String,
        overridePath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [URL]? = nil
    ) -> CLIToolDiscoveryResult {
        if let overridePath, overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let trimmed = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: trimmed)
            if FileManager.default.fileExists(atPath: url.path) == false {
                return CLIToolDiscoveryResult(
                    toolName: toolName,
                    state: .invalid,
                    executablePath: trimmed,
                    source: .manualOverride,
                    reasonCode: .overrideNotFound
                )
            }

            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                return CLIToolDiscoveryResult(
                    toolName: toolName,
                    state: .invalid,
                    executablePath: trimmed,
                    source: .manualOverride,
                    reasonCode: .overrideIsDirectory
                )
            }

            if isExecutableFile(url) {
                return CLIToolDiscoveryResult(
                    toolName: toolName,
                    state: .found,
                    executablePath: url.path,
                    source: .manualOverride,
                    reasonCode: nil
                )
            }

            return CLIToolDiscoveryResult(
                toolName: toolName,
                state: .invalid,
                executablePath: trimmed,
                source: .manualOverride,
                reasonCode: .overrideNotExecutable
            )
        }

        if let found = findExecutable(named: toolName, searchPaths: pathSearchPaths(from: environment)) {
            return CLIToolDiscoveryResult(
                toolName: toolName,
                state: .found,
                executablePath: found.path,
                source: .path,
                reasonCode: nil
            )
        }

        let fallback = fallbackDirectories ?? defaultFallbackDirectories()
        if let found = findExecutable(named: toolName, searchPaths: fallback) {
            return CLIToolDiscoveryResult(
                toolName: toolName,
                state: .found,
                executablePath: found.path,
                source: .fallbackDirectory,
                reasonCode: nil
            )
        }

        return CLIToolDiscoveryResult(
            toolName: toolName,
            state: .missing,
            executablePath: nil,
            source: nil,
            reasonCode: .notFound
        )
    }

    static func probeHealth(
        toolName: String,
        overridePath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [URL]? = nil,
        versionTimeoutSec: TimeInterval = 0.5
    ) -> CLIToolHealthProbeResult {
        let discovery = discover(
            toolName: toolName,
            overridePath: overridePath,
            environment: environment,
            fallbackDirectories: fallbackDirectories
        )

        let version = probeVersion(discovery: discovery, timeoutSec: versionTimeoutSec)

        if let logger = diagnosticsLogger(toolName: toolName) {
            logger.info(
                "cli_tool_probe",
                fields: [
                    "state": .string(discovery.state.rawValue),
                    "source": discovery.source.map { .string($0.rawValue) } ?? .null,
                    "reasonCode": discovery.reasonCode.map { .string($0.rawValue) } ?? .null,
                    "executablePath": discovery.executablePath.map { .string($0) } ?? .null,
                    "versionState": .string(version.state.rawValue),
                    "version": version.version.map { .string($0) } ?? .null,
                    "versionReasonCode": version.reasonCode.map { .string($0.rawValue) } ?? .null,
                ]
            )
        }

        return CLIToolHealthProbeResult(
            state: discovery.state,
            discovery: discovery,
            version: version
        )
    }

    private static func diagnosticsLogger(toolName: String) -> DiagnosticsLogger? {
        guard let provider = ProviderId(rawValue: toolName) else { return nil }
        return DiagnosticsLogger(provider: provider)
    }

    static func probeHealthAsync(
        toolName: String,
        overridePath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [URL]? = nil,
        versionTimeoutSec: TimeInterval = 0.5
    ) async -> CLIToolHealthProbeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(
                    returning: probeHealth(
                        toolName: toolName,
                        overridePath: overridePath,
                        environment: environment,
                        fallbackDirectories: fallbackDirectories,
                        versionTimeoutSec: versionTimeoutSec
                    )
                )
            }
        }
    }

    static func defaultSearchPaths() -> [URL] {
        let pathDirs = pathSearchPaths(from: ProcessInfo.processInfo.environment)
        let fallbackDirs = defaultFallbackDirectories()
        return dedupedDirectories(pathDirs + fallbackDirs)
    }

    static func defaultFallbackDirectories() -> [URL] {
        var urls: [URL] = []
        urls.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        urls.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))
        urls.append(URL(fileURLWithPath: "/usr/bin", isDirectory: true))

        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent("bin", isDirectory: true))

        return dedupedDirectories(urls)
    }

    static func pathSearchPaths(from environment: [String: String]) -> [URL] {
        guard let path = environment["PATH"] else { return [] }
        var urls: [URL] = []
        for part in path.split(separator: ":") {
            let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            urls.append(URL(fileURLWithPath: trimmed, isDirectory: true))
        }
        return dedupedDirectories(urls)
    }

    static func probeVersion(discovery: CLIToolDiscoveryResult, timeoutSec: TimeInterval) -> CLIToolVersionProbeResult {
        switch discovery.state {
        case .missing:
            return CLIToolVersionProbeResult(state: .missing, version: nil, reasonCode: .notFound)
        case .invalid:
            return CLIToolVersionProbeResult(state: .invalid, version: nil, reasonCode: discovery.reasonCode)
        case .found:
            guard let path = discovery.executablePath else {
                return CLIToolVersionProbeResult(state: .invalid, version: nil, reasonCode: .versionLaunchFailed)
            }
            return probeVersion(executableURL: URL(fileURLWithPath: path), timeoutSec: timeoutSec)
        }
    }

    static func probeVersion(executableURL: URL, timeoutSec: TimeInterval) -> CLIToolVersionProbeResult {
        let run = runAndCapture(executableURL: executableURL, arguments: ["--version"], timeoutSec: timeoutSec)
        switch run {
        case .launchFailed:
            return CLIToolVersionProbeResult(state: .invalid, version: nil, reasonCode: .versionLaunchFailed)
        case .timedOut:
            return CLIToolVersionProbeResult(state: .invalid, version: nil, reasonCode: .versionTimedOut)
        case .completed(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                return CLIToolVersionProbeResult(state: .invalid, version: nil, reasonCode: .versionOutputEmpty)
            }
            guard let version = firstVersionLikeString(in: trimmed) else {
                return CLIToolVersionProbeResult(state: .invalid, version: nil, reasonCode: .versionParseFailed)
            }
            return CLIToolVersionProbeResult(state: .found, version: version, reasonCode: nil)
        }
    }

    private enum RunResult {
        case completed(output: String)
        case timedOut
        case launchFailed
    }

    private static func runAndCapture(
        executableURL: URL,
        arguments: [String],
        timeoutSec: TimeInterval
    ) -> RunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let sema = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sema.signal() }

        do {
            try process.run()
        } catch {
            return .launchFailed
        }

        if sema.wait(timeout: .now() + timeoutSec) == .timedOut {
            process.terminate()
            _ = sema.wait(timeout: .now() + 0.2)
            return .timedOut
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        return .completed(output: out + (out.isEmpty || err.isEmpty ? "" : "\n") + err)
    }

    private static func firstVersionLikeString(in text: String) -> String? {
        let pattern = "\\b\\d+(?:\\.\\d+){1,3}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }

    private static func dedupedDirectories(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.isEmpty == false else { continue }
            guard seen.insert(path).inserted else { continue }
            out.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return out
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
