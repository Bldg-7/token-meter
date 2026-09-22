import Foundation

enum CollectionTrackId: String, Hashable, Sendable {
    case track1
    case track2
}

struct CollectionRefreshKey: Hashable, Sendable {
    var provider: ProviderId
    var track: CollectionTrackId
}

struct CollectionBackoffPolicy: Sendable {
    var baseNanoseconds: UInt64
    var maxNanoseconds: UInt64

    init(baseNanoseconds: UInt64, maxNanoseconds: UInt64) {
        self.baseNanoseconds = baseNanoseconds
        self.maxNanoseconds = maxNanoseconds
    }

    static func `default`() -> CollectionBackoffPolicy {
        CollectionBackoffPolicy(baseNanoseconds: 2 * 1_000_000_000, maxNanoseconds: 5 * 60 * 1_000_000_000)
    }
}

struct CollectionUnitConfig: Sendable {
    var periodNanoseconds: UInt64
    var timeoutNanoseconds: UInt64
    var backoff: CollectionBackoffPolicy

    init(periodNanoseconds: UInt64, timeoutNanoseconds: UInt64, backoff: CollectionBackoffPolicy = .default()) {
        self.periodNanoseconds = periodNanoseconds
        self.timeoutNanoseconds = timeoutNanoseconds
        self.backoff = backoff
    }
}

struct CollectionUnit: Sendable {
    var key: CollectionRefreshKey
    var config: CollectionUnitConfig
    var operation: @Sendable () async throws -> Void

    init(key: CollectionRefreshKey, config: CollectionUnitConfig, operation: @escaping @Sendable () async throws -> Void) {
        self.key = key
        self.config = config
        self.operation = operation
    }
}

enum CollectionUnitPhase: Sendable, Equatable {
    case idle
    case sleeping(untilNanoseconds: UInt64)
    case running
    case backingOff(untilNanoseconds: UInt64)
    case stopped
}

struct CollectionUnitHealth: Sendable, Equatable {
    var phase: CollectionUnitPhase
    var consecutiveFailures: Int
    var lastAttemptAtNanoseconds: UInt64?
    var lastSuccessAtNanoseconds: UInt64?
    var lastError: String?
}

actor CollectionOrchestrator {
    typealias HealthDidChange = @Sendable (CollectionRefreshKey, CollectionUnitHealth) -> Void

    nonisolated let clock: OrchestratorClock

    private let units: [CollectionRefreshKey: CollectionUnit]
    private let healthDidChange: HealthDidChange?

    private var tasksByKey: [CollectionRefreshKey: Task<Void, Never>] = [:]
    private var stateByKey: [CollectionRefreshKey: UnitState] = [:]

    init(
        clock: OrchestratorClock = SystemOrchestratorClock(),
        units: [CollectionUnit],
        healthDidChange: HealthDidChange? = nil
    ) {
        self.clock = clock
        self.units = Dictionary(uniqueKeysWithValues: units.map { ($0.key, $0) })
        self.healthDidChange = healthDidChange

        for unit in units {
            stateByKey[unit.key] = UnitState(config: unit.config)
        }
    }

    func start() {
        for (key, unit) in units {
            if tasksByKey[key] != nil {
                continue
            }

            let task = Task {
                await self.runLoop(key: key, unit: unit)
            }
            tasksByKey[key] = task
        }
    }

    func stop() async {
        let now = await clock.nowNanoseconds()

        for (_, task) in tasksByKey {
            task.cancel()
        }
        tasksByKey.removeAll(keepingCapacity: true)

        for key in units.keys {
            setPhase(.stopped, for: key, at: now)
        }
    }

    func healthSnapshot() async -> [CollectionRefreshKey: CollectionUnitHealth] {
        var out: [CollectionRefreshKey: CollectionUnitHealth] = [:]
        out.reserveCapacity(stateByKey.count)
        for (key, state) in stateByKey {
            out[key] = state.health
        }
        return out
    }

    private func setPhase(_ phase: CollectionUnitPhase, for key: CollectionRefreshKey, at now: UInt64) {
        guard var state = stateByKey[key] else { return }
        state.health.phase = phase
        stateByKey[key] = state
        emitHealthDidChange(key: key, health: state.health)
    }

    private func recordAttemptStart(for key: CollectionRefreshKey, at now: UInt64) {
        guard var state = stateByKey[key] else { return }
        state.health.phase = .running
        state.health.lastAttemptAtNanoseconds = now
        state.health.lastError = nil
        stateByKey[key] = state
        emitHealthDidChange(key: key, health: state.health)
    }

    private func recordSuccess(for key: CollectionRefreshKey, at now: UInt64) {
        guard var state = stateByKey[key] else { return }
        state.health.consecutiveFailures = 0
        state.health.lastSuccessAtNanoseconds = now
        state.health.lastError = nil
        stateByKey[key] = state
        emitHealthDidChange(key: key, health: state.health)
    }

    private func recordFailure(for key: CollectionRefreshKey, at now: UInt64, error: String) {
        guard var state = stateByKey[key] else { return }
        state.health.consecutiveFailures += 1
        state.health.lastError = error
        stateByKey[key] = state
        emitHealthDidChange(key: key, health: state.health)
    }

    private func emitHealthDidChange(key: CollectionRefreshKey, health: CollectionUnitHealth) {
        healthDidChange?(key, health)
    }

    private nonisolated func runLoop(key: CollectionRefreshKey, unit: CollectionUnit) async {
        let clock = self.clock
        let logger = DiagnosticsLogger(provider: key.provider)

        var due = await clock.nowNanoseconds()
        // An attempt that outlived its timeout may still be running (a child
        // process ignores task cancellation); it is remembered so a second
        // attempt is never stacked on top of it.
        var runaway: RunningOperation?

        while Task.isCancelled == false {
            do {
                await self.setPhase(.sleeping(untilNanoseconds: due), for: key, at: await clock.nowNanoseconds())
                try await clock.sleep(untilNanoseconds: due)
            } catch {
                break
            }

            let startedAt = await clock.nowNanoseconds()

            if let previous = runaway, previous.isFinished == false {
                await self.recordFailure(for: key, at: startedAt, error: "previous attempt still running")
                due = await self.backoffDue(for: key, unit: unit, from: startedAt)
                continue
            }
            runaway = nil

            await self.recordAttemptStart(for: key, at: startedAt)

            let attempt = await CollectionOrchestrator.runWithTimeout(
                clock: clock,
                timeoutNanoseconds: unit.config.timeoutNanoseconds,
                operation: unit.operation
            )

            let finishedAt = await clock.nowNanoseconds()

            switch attempt.result {
            case .success:
                await self.recordSuccess(for: key, at: finishedAt)
                due = finishedAt &+ unit.config.periodNanoseconds
            case .failure(let message):
                await self.recordFailure(for: key, at: finishedAt, error: message)
                due = await self.backoffDue(for: key, unit: unit, from: finishedAt)
            case .timeout:
                runaway = attempt.operation
                await self.recordFailure(for: key, at: finishedAt, error: "timeout")
                due = await self.backoffDue(for: key, unit: unit, from: finishedAt)
            }

            logger.debug(
                "collection_tick",
                fields: [
                    "track": .string(key.track.rawValue),
                    "phase": .string(await self.phaseString(for: key)),
                    "nextDueNs": .string(String(due)),
                ]
            )
        }
    }

    /// Schedules the next attempt after a failure and reports the backoff
    /// phase; returns the deadline.
    private func backoffDue(for key: CollectionRefreshKey, unit: CollectionUnit, from now: UInt64) -> UInt64 {
        let failures = consecutiveFailures(for: key)
        let backoffDelay = CollectionOrchestrator.backoffDelayNanoseconds(
            consecutiveFailures: failures,
            policy: unit.config.backoff
        )
        let due = now &+ backoffDelay
        setPhase(.backingOff(untilNanoseconds: due), for: key, at: now)
        return due
    }

    private func phaseString(for key: CollectionRefreshKey) async -> String {
        guard let state = stateByKey[key] else { return "unknown" }
        switch state.health.phase {
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

    private func consecutiveFailures(for key: CollectionRefreshKey) -> Int {
        stateByKey[key]?.health.consecutiveFailures ?? 0
    }

    private enum RunResult: Sendable, Equatable {
        case success
        case failure(String)
        case timeout
    }

    private struct AttemptOutcome {
        var result: RunResult
        var operation: RunningOperation
    }

    /// Tracks an operation task past the point the orchestrator stopped
    /// waiting for it.
    private final class RunningOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func markFinished() {
            lock.lock()
            finished = true
            lock.unlock()
        }
    }

    /// Hands the first of two results to a single waiter; later results are
    /// dropped.
    private final class FirstResultGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: RunResult?
        private var continuation: CheckedContinuation<RunResult, Never>?

        func resolve(_ value: RunResult) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = value
            let waiter = continuation
            continuation = nil
            lock.unlock()
            waiter?.resume(returning: value)
        }

        func value() async -> RunResult {
            await withCheckedContinuation { waiter in
                lock.lock()
                if let result {
                    lock.unlock()
                    waiter.resume(returning: result)
                    return
                }
                continuation = waiter
                lock.unlock()
            }
        }
    }

    /// Races `operation` against the timeout and returns as soon as either
    /// finishes. The loser is cancelled but never awaited: a task group would
    /// wait for an operation that ignores cancellation (blocking process or
    /// network calls), which made the timeout a no-op and then reported the
    /// completed work as a failure.
    private static func runWithTimeout(
        clock: OrchestratorClock,
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Void
    ) async -> AttemptOutcome {
        let running = RunningOperation()
        let gate = FirstResultGate()

        let operationTask = Task<Void, Never> {
            let result: RunResult
            do {
                try await operation()
                result = .success
            } catch {
                if error is CancellationError {
                    result = .failure("cancelled")
                } else {
                    result = .failure(String(describing: error))
                }
            }
            running.markFinished()
            gate.resolve(result)
        }

        let timeoutTask = Task<Void, Never> {
            do {
                try await clock.sleep(forNanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            gate.resolve(.timeout)
        }

        let result = await gate.value()
        if result == .timeout {
            operationTask.cancel()
        } else {
            timeoutTask.cancel()
        }
        return AttemptOutcome(result: result, operation: running)
    }

    private static func backoffDelayNanoseconds(
        consecutiveFailures: Int,
        policy: CollectionBackoffPolicy
    ) -> UInt64 {
        guard consecutiveFailures > 0 else { return 0 }

        let maxShift = 30
        let shift = min(max(0, consecutiveFailures - 1), maxShift)
        let factor = UInt64(1) << UInt64(shift)

        let base = policy.baseNanoseconds
        let (multiplied, overflow) = base.multipliedReportingOverflow(by: factor)
        if overflow {
            return policy.maxNanoseconds
        }

        return min(multiplied, policy.maxNanoseconds)
    }

    private struct UnitState: Sendable {
        var config: CollectionUnitConfig
        var health: CollectionUnitHealth

        init(config: CollectionUnitConfig) {
            self.config = config
            self.health = CollectionUnitHealth(
                phase: .idle,
                consecutiveFailures: 0,
                lastAttemptAtNanoseconds: nil,
                lastSuccessAtNanoseconds: nil,
                lastError: nil
            )
        }
    }
}
