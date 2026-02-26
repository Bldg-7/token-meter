import Foundation

enum TrackConfidence: String, Codable, Equatable {
    case high
    case medium
    case low
}

enum Track1Source: String, Codable, Equatable {
    case cliMethodB = "cli_method_b"
    case webMethodC = "web_method_c"
}

enum Track1PlanLabel: String, Codable, Equatable {
    case free
    case plus
    case pro
    case max
    case team
    case business
    case enterprise
    case unknown
}

enum Track1WindowId: String, Codable, Equatable {
    case session
    case rolling5h = "rolling_5h"
    case weekly
    case modelSpecific = "model_specific"
}

struct Track1Window: Codable, Equatable {
    var windowId: Track1WindowId
    var usedPercent: Double?
    var remainingPercent: Double?
    var resetAt: Date?
    var rawScopeLabel: String
}

struct Track1Snapshot: Codable, Equatable {
    var provider: ProviderId
    var observedAt: Date
    var source: Track1Source
    var plan: Track1PlanLabel
    var windows: [Track1Window]
    var confidence: TrackConfidence
    var parserVersion: String
}

struct Track2TimelinePoint: Codable, Equatable {
    var provider: ProviderId
    var timestamp: Date
    var sessionId: String?
    var model: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var sourceFile: String
    var confidence: TrackConfidence
    var parserVersion: String
}
