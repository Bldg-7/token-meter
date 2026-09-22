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
        let outcome: ProcessCaptureOutcome
        do {
            outcome = try ProcessExecution.run(
                executableURL: executableURL,
                arguments: arguments,
                timeoutSec: timeoutSec
            )
        } catch {
            return .launchFailed
        }

        switch outcome {
        case .timedOut:
            return .timedOut
        case .completed(_, let outData, let errData):
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            return .completed(output: out + (out.isEmpty || err.isEmpty ? "" : "\n") + err)
        }
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

/// Outcome of running a child process to completion or to its deadline.
enum ProcessCaptureOutcome: Sendable {
    case completed(status: Int32, stdout: Data, stderr: Data)
    /// The child outlived `timeoutSec` and was terminated; carries whatever it
    /// had written by then.
    case timedOut(stdout: Data, stderr: Data)
}

/// Runs a child process without the two classic Foundation pitfalls.
///
/// The stdout/stderr pipes are drained from the moment the child starts, so a
/// child that writes more than the pipe buffer (64KB) can never block on
/// `write` while the parent blocks in `waitUntilExit` — a deadlock neither
/// side recovers from. And a deadline terminates a child that hangs (SIGTERM,
/// then SIGKILL) instead of hanging the caller with it.
///
/// A child that is given no stdin gets `/dev/null` rather than inheriting the
/// app's: a CLI launched from a terminal would otherwise see a TTY and may
/// start an interactive session that never exits.
enum ProcessExecution {
    static func run(
        executableURL: URL,
        arguments: [String],
        stdinData: Data? = nil,
        stdinCloseDelaySec: TimeInterval = 0,
        timeoutSec: TimeInterval
    ) throws -> ProcessCaptureOutcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        let deadline = DispatchTime.now() + timeoutSec

        let stdoutDrain = PipeDrain(handle: stdoutPipe.fileHandleForReading)
        let stderrDrain = PipeDrain(handle: stderrPipe.fileHandleForReading)

        var exitedBeforeDeadline = false
        if let stdinData, let stdinPipe {
            let handle = stdinPipe.fileHandleForWriting
            // A child that exits before reading its stdin makes this write
            // fail with EPIPE; the exit status tells the story, not the write.
            try? handle.write(contentsOf: stdinData)
            if stdinCloseDelaySec > 0 {
                // Some tools answer only while stdin stays open; hold it, but
                // wake as soon as the child exits on its own.
                let holdUntil = min(deadline, DispatchTime.now() + stdinCloseDelaySec)
                exitedBeforeDeadline = exited.wait(timeout: holdUntil) == .success
            }
            try? handle.close()
        }

        if exitedBeforeDeadline == false {
            exitedBeforeDeadline = exited.wait(timeout: deadline) == .success
        }

        if exitedBeforeDeadline == false {
            process.terminate()
            if exited.wait(timeout: .now() + 1.0) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1.0)
            }
        }

        // The pipes reach EOF once every holder of their write end is gone; a
        // grandchild that inherited them can keep them open, so bound the wait.
        let stdout = stdoutDrain.finish(within: 2.0)
        let stderr = stderrDrain.finish(within: 2.0)

        if exitedBeforeDeadline {
            return .completed(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        }
        return .timedOut(stdout: stdout, stderr: stderr)
    }

    /// Reads a pipe to EOF on a background thread from the moment it is
    /// created, so the writer never stalls on a full pipe.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(handle: FileHandle) {
            self.handle = handle
            DispatchQueue.global(qos: .utility).async { [self] in
                while true {
                    let chunk = self.handle.availableData
                    if chunk.isEmpty {
                        break
                    }
                    lock.lock()
                    data.append(chunk)
                    lock.unlock()
                }
                done.signal()
            }
        }

        func finish(within seconds: TimeInterval) -> Data {
            _ = done.wait(timeout: .now() + seconds)
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
