import Foundation

enum ClaudeTrack1AdapterError: Error, Equatable {
    case methodCNotAllowed
}

struct ClaudeTrack1Adapter {
    static func snapshot(from data: Data, settings: ClaudeSettings, observedAt: Date = Date()) throws -> Track1Snapshot {
        switch settings.track1Source {
        case .methodB:
            return try ClaudeTrack1MethodBAdapter.snapshot(from: data, observedAt: observedAt)
        case .methodC:
            guard settings.allowMethodC else {
                throw ClaudeTrack1AdapterError.methodCNotAllowed
            }
            return try ClaudeTrack1MethodCAdapter.snapshot(from: data, observedAt: observedAt)
        }
    }
}
