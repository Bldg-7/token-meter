import Foundation

enum ClaudeTrack1MethodBAdapterError: Error, Equatable {
    case missingWindows
    case invalidWindow(index: Int)
    case invalidJSON
}

struct ClaudeTrack1MethodBAdapter {
    static let parserVersion = "claude_track1_method_b_v1"

    static func snapshot(from data: Data, observedAt: Date = Date()) throws -> Track1Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload: MethodBPayload
        do {
            payload = try decoder.decode(MethodBPayload.self, from: data)
        } catch {
            throw ClaudeTrack1MethodBAdapterError.invalidJSON
        }

        guard payload.windows.isEmpty == false else {
            throw ClaudeTrack1MethodBAdapterError.missingWindows
        }

        let plan = Track1PlanLabel.normalized(from: payload.plan)

        var windows: [Track1Window] = []
        windows.reserveCapacity(payload.windows.count)

        var degraded = false
        for (idx, w) in payload.windows.enumerated() {
            guard let windowId = Track1WindowId.normalized(from: w.windowId) else {
                throw ClaudeTrack1MethodBAdapterError.invalidWindow(index: idx)
            }
            let scope = w.scopeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard scope.isEmpty == false else {
                throw ClaudeTrack1MethodBAdapterError.invalidWindow(index: idx)
            }

            let resetAt = w.resetAt?.date
            if resetAt == nil { degraded = true }
            if w.usedPercent == nil && w.remainingPercent == nil { degraded = true }
            if plan == .unknown { degraded = true }

            windows.append(
                Track1Window(
                    windowId: windowId,
                    usedPercent: w.usedPercent,
                    remainingPercent: w.remainingPercent,
                    resetAt: resetAt,
                    rawScopeLabel: scope
                )
            )
        }

        return Track1Snapshot(
            provider: .claude,
            observedAt: observedAt,
            source: .cliMethodB,
            plan: plan,
            windows: windows,
            confidence: degraded ? .medium : .high,
            parserVersion: parserVersion
        )
    }
}

private struct MethodBPayload: Decodable {
    var plan: String?
    var windows: [MethodBWindow]

    private enum CodingKeys: String, CodingKey {
        case plan
        case planLabel
        case plan_label
        case tier

        case windows
        case limits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let plan = try c.decodeIfPresent(String.self, forKey: .plan) {
            self.plan = plan
        } else if let plan = try c.decodeIfPresent(String.self, forKey: .planLabel) {
            self.plan = plan
        } else if let plan = try c.decodeIfPresent(String.self, forKey: .plan_label) {
            self.plan = plan
        } else {
            self.plan = try c.decodeIfPresent(String.self, forKey: .tier)
        }

        if let windows = try c.decodeIfPresent([MethodBWindow].self, forKey: .windows) {
            self.windows = windows
        } else if let limits = try c.decodeIfPresent([MethodBWindow].self, forKey: .limits) {
            self.windows = limits
        } else {
            self.windows = []
        }
    }
}

private struct MethodBWindow: Decodable {
    var windowId: String
    var scopeLabel: String
    var usedPercent: Double?
    var remainingPercent: Double?
    var resetAt: FlexibleDate?

    private enum CodingKeys: String, CodingKey {
        case windowId
        case window_id
        case window
        case id

        case scope
        case scopeLabel
        case scope_label
        case rawScopeLabel
        case raw_scope_label

        case usedPercent
        case used_percent
        case usedPct
        case used_pct

        case remainingPercent
        case remaining_percent
        case remainingPct
        case remaining_pct

        case resetAt
        case reset_at
        case resetsAt
        case resets_at
        case reset
        case resetTs
        case reset_ts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func decodeFirst<T: Decodable>(_ type: T.Type, keys: [CodingKeys]) throws -> T? {
            for key in keys {
                if let v = try c.decodeIfPresent(T.self, forKey: key) {
                    return v
                }
            }
            return nil
        }

        self.windowId = try decodeFirst(String.self, keys: [.windowId, .window_id, .window, .id]) ?? ""
        self.scopeLabel = try decodeFirst(String.self, keys: [.scope, .scopeLabel, .scope_label, .rawScopeLabel, .raw_scope_label]) ?? ""
        self.usedPercent = try decodeFirst(Double.self, keys: [.usedPercent, .used_percent, .usedPct, .used_pct])
        self.remainingPercent = try decodeFirst(Double.self, keys: [.remainingPercent, .remaining_percent, .remainingPct, .remaining_pct])
        self.resetAt = try decodeFirst(FlexibleDate.self, keys: [.resetAt, .reset_at, .resetsAt, .resets_at, .reset, .resetTs, .reset_ts])
    }
}

private struct FlexibleDate: Decodable {
    var date: Date

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            if let d = FlexibleDate.parseISO8601(s) {
                self.date = d
                return
            }
        }

        if let i = try? c.decode(Int64.self) {
            self.date = FlexibleDate.fromEpochSecondsOrMillis(i)
            return
        }
        if let d = try? c.decode(Double.self) {
            self.date = FlexibleDate.fromEpochSecondsOrMillis(Int64(d))
            return
        }

        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported date format")
    }

    private static func fromEpochSecondsOrMillis(_ epoch: Int64) -> Date {
        if epoch > 10_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(epoch) / 1000.0)
        }
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: trimmed) { return d }

        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: trimmed)
    }
}

private extension Track1PlanLabel {
    static func normalized(from raw: String?) -> Track1PlanLabel {
        guard let raw else { return .unknown }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return .unknown }

        let s = trimmed
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch s {
        case "free":
            return .free
        case "plus", "chatgpt_plus":
            return .plus
        case "pro", "chatgpt_pro":
            return .pro
        case "max", "chatgpt_max":
            return .max
        case "team":
            return .team
        case "business":
            return .business
        case "enterprise":
            return .enterprise
        default:
            return .unknown
        }
    }
}

private extension Track1WindowId {
    static func normalized(from raw: String) -> Track1WindowId? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let s = trimmed
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch s {
        case "session":
            return .session
        case "rolling_5h", "rolling5h", "rolling_5_hours", "rolling5hours":
            return .rolling5h
        case "weekly", "week":
            return .weekly
        case "model_specific", "model":
            return .modelSpecific
        default:
            return nil
        }
    }
}
