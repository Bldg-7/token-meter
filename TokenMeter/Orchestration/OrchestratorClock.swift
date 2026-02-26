import Dispatch
import Foundation

protocol OrchestratorClock: Sendable {
    func nowNanoseconds() async -> UInt64
    func sleep(untilNanoseconds deadline: UInt64) async throws
}

extension OrchestratorClock {
    func sleep(forNanoseconds duration: UInt64) async throws {
        let now = await nowNanoseconds()
        try await sleep(untilNanoseconds: now &+ duration)
    }
}

struct SystemOrchestratorClock: OrchestratorClock {
    func nowNanoseconds() async -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        if deadline <= now {
            return
        }
        try await Task.sleep(nanoseconds: deadline - now)
    }
}
