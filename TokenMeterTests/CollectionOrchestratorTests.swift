import XCTest

@testable import TokenMeter

final class CollectionOrchestratorTests: XCTestCase {
    func testPeriodicCollectionRunsOnSuccessSchedule() async {
        let clock = ManualOrchestratorClock(nowNanoseconds: 0)
        let log = CallLog()

        let key = CollectionRefreshKey(provider: .codex, track: .track2)
        let unit = CollectionUnit(
            key: key,
            config: CollectionUnitConfig(
                periodNanoseconds: 10,
                timeoutNanoseconds: 5,
                backoff: CollectionBackoffPolicy(baseNanoseconds: 100, maxNanoseconds: 1000)
            ),
            operation: {
                let t = await clock.nowNanoseconds()
                await log.record(key: key, at: t)
            }
        )

        let orchestrator = CollectionOrchestrator(clock: clock, units: [unit])
        await drainScheduler()
        await orchestrator.start()
        await drainScheduler()

        let c1 = await log.count(key: key)
        XCTAssertEqual(c1, 1)

        await clock.advance(byNanoseconds: 10)
        await drainScheduler()
        let c2 = await log.count(key: key)
        XCTAssertEqual(c2, 2)

        await clock.advance(byNanoseconds: 10)
        await drainScheduler()
        let c3 = await log.count(key: key)
        XCTAssertEqual(c3, 3)

        await orchestrator.stop()
    }

    func testBackoffIsScopedPerKeyWithoutBlockingOtherKeys() async {
        enum TestError: Error { case fail }

        let clock = ManualOrchestratorClock(nowNanoseconds: 0)
        let log = CallLog()

        let failingKey = CollectionRefreshKey(provider: .claude, track: .track1)
        let healthyKey = CollectionRefreshKey(provider: .codex, track: .track2)

        let failingUnit = CollectionUnit(
            key: failingKey,
            config: CollectionUnitConfig(
                periodNanoseconds: 10,
                timeoutNanoseconds: 5,
                backoff: CollectionBackoffPolicy(baseNanoseconds: 15, maxNanoseconds: 60)
            ),
            operation: {
                let t = await clock.nowNanoseconds()
                await log.record(key: failingKey, at: t)
                throw TestError.fail
            }
        )

        let healthyUnit = CollectionUnit(
            key: healthyKey,
            config: CollectionUnitConfig(
                periodNanoseconds: 10,
                timeoutNanoseconds: 5,
                backoff: CollectionBackoffPolicy(baseNanoseconds: 100, maxNanoseconds: 1000)
            ),
            operation: {
                let t = await clock.nowNanoseconds()
                await log.record(key: healthyKey, at: t)
            }
        )

        let orchestrator = CollectionOrchestrator(clock: clock, units: [failingUnit, healthyUnit])
        await orchestrator.start()
        await drainScheduler()

        let f1 = await log.count(key: failingKey)
        let h1 = await log.count(key: healthyKey)
        XCTAssertEqual(f1, 1)
        XCTAssertEqual(h1, 1)

        await clock.advance(byNanoseconds: 10)
        await drainScheduler()
        let f2 = await log.count(key: failingKey)
        let h2 = await log.count(key: healthyKey)
        XCTAssertEqual(f2, 1)
        XCTAssertEqual(h2, 2)

        await clock.advance(byNanoseconds: 5)
        await drainScheduler()
        let f3 = await log.count(key: failingKey)
        let h3 = await log.count(key: healthyKey)
        XCTAssertEqual(f3, 2)
        XCTAssertEqual(h3, 2)

        await clock.advance(byNanoseconds: 5)
        await drainScheduler()
        let f4 = await log.count(key: failingKey)
        let h4 = await log.count(key: healthyKey)
        XCTAssertEqual(f4, 2)
        XCTAssertEqual(h4, 3)

        await clock.advance(byNanoseconds: 10)
        await drainScheduler()
        let f5 = await log.count(key: failingKey)
        let h5 = await log.count(key: healthyKey)
        XCTAssertEqual(f5, 2)
        XCTAssertEqual(h5, 4)

        await clock.advance(byNanoseconds: 10)
        await drainScheduler()
        let f6 = await log.count(key: failingKey)
        let h6 = await log.count(key: healthyKey)
        XCTAssertEqual(f6, 2)
        XCTAssertEqual(h6, 5)

        await orchestrator.stop()
    }

    func testTimeoutBackoffDoesNotBlockOtherKeys() async {
        let clock = ManualOrchestratorClock(nowNanoseconds: 0)
        let log = CallLog()

        let timeoutKey = CollectionRefreshKey(provider: .claude, track: .track2)
        let healthyKey = CollectionRefreshKey(provider: .codex, track: .track1)

        let timeoutUnit = CollectionUnit(
            key: timeoutKey,
            config: CollectionUnitConfig(
                periodNanoseconds: 10,
                timeoutNanoseconds: 5,
                backoff: CollectionBackoffPolicy(baseNanoseconds: 10, maxNanoseconds: 100)
            ),
            operation: {
                let t = await clock.nowNanoseconds()
                await log.record(key: timeoutKey, at: t)
                try await clock.sleep(untilNanoseconds: 1_000_000)
            }
        )

        let healthyUnit = CollectionUnit(
            key: healthyKey,
            config: CollectionUnitConfig(
                periodNanoseconds: 10,
                timeoutNanoseconds: 5,
                backoff: CollectionBackoffPolicy(baseNanoseconds: 100, maxNanoseconds: 1000)
            ),
            operation: {
                let t = await clock.nowNanoseconds()
                await log.record(key: healthyKey, at: t)
            }
        )

        let orchestrator = CollectionOrchestrator(clock: clock, units: [timeoutUnit, healthyUnit])
        await orchestrator.start()
        await drainScheduler()

        let t1 = await log.count(key: timeoutKey)
        let h1 = await log.count(key: healthyKey)
        XCTAssertEqual(t1, 1)
        XCTAssertEqual(h1, 1)

        await clock.advance(byNanoseconds: 10)
        await drainScheduler()
        let t2 = await log.count(key: timeoutKey)
        let h2 = await log.count(key: healthyKey)
        XCTAssertEqual(t2, 1)
        XCTAssertEqual(h2, 2)

        await clock.advance(byNanoseconds: 5)
        await drainScheduler()
        let h3 = await log.count(key: healthyKey)
        XCTAssertEqual(h3, 2)

        await clock.advance(byNanoseconds: 5)
        await drainScheduler()
        let h4 = await log.count(key: healthyKey)
        XCTAssertEqual(h4, 3)

        await orchestrator.stop()
    }

    private func drainScheduler(iterations: Int = 10000) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }
}

actor CallLog {
    private var calls: [CollectionRefreshKey: [UInt64]] = [:]

    func record(key: CollectionRefreshKey, at t: UInt64) {
        calls[key, default: []].append(t)
    }

    func count(key: CollectionRefreshKey) -> Int {
        calls[key]?.count ?? 0
    }
}

actor ManualOrchestratorClock: OrchestratorClock {
    private var nowNs: UInt64
    private var waiters: [UUID: Waiter] = [:]

    init(nowNanoseconds: UInt64) {
        self.nowNs = nowNanoseconds
    }

    func nowNanoseconds() async -> UInt64 {
        nowNs
    }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        if deadline <= nowNs {
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { cont in
                waiters[id] = Waiter(deadline: deadline, continuation: cont)
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: id) }
        })
    }

    func advance(byNanoseconds delta: UInt64) {
        nowNs &+= delta
        let due = waiters.filter { _, w in w.deadline <= nowNs }
        for (id, waiter) in due {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: ())
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
}
