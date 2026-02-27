import Foundation

struct CodexTrack2PrimaryParser {
    static let parserVersion = "codex_track2_primary_v2"
    fileprivate static let nearbyModelLineWindow = 6
    fileprivate static let nearbyModelHistoryLimit = 64

    static func timelinePoints(from data: Data, sourceFile: String) -> [Track2TimelinePoint] {
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return timelinePoints(fromJSONL: text, sourceFile: sourceFile)
    }

    static func timelinePoints(fromJSONL text: String, sourceFile: String) -> [Track2TimelinePoint] {
        var points: [Track2TimelinePoint] = []
        var lastKnownModelBySession: [String: String] = [:]
        var lastCumulativeTotalsBySession: [String: Int] = [:]
        var seenCumulativeTotals: Set<String> = []
        var recentModels: [RecentModelContext] = []
        var lineIndex = 0

        text.enumerateLines { line, _ in
            defer { lineIndex += 1 }

            guard let parsed = parseLine(line) else {
                return
            }

            if let model = normalizedModel(parsed.model) {
                if let sessionId = parsed.sessionId {
                    lastKnownModelBySession[sessionId] = model
                }
                pushRecentModel(
                    sessionId: parsed.sessionId,
                    model: model,
                    lineIndex: lineIndex,
                    into: &recentModels
                )
            }

            if let cumulativeTotalTokens = parsed.cumulativeTotalTokens {
                let sessionKey = normalizedSessionKey(parsed.sessionId)
                let dedupKey = "\(sessionKey)|\(cumulativeTotalTokens)"
                if seenCumulativeTotals.insert(dedupKey).inserted == false {
                    return
                }
            }

            guard var point = makePoint(
                from: parsed,
                sourceFile: sourceFile,
                lastCumulativeTotalsBySession: &lastCumulativeTotalsBySession
            ) else {
                return
            }

            if let sessionId = point.sessionId {
                if let model = normalizedModel(point.model) {
                    point.model = model
                } else if let inferredModel = lastKnownModelBySession[sessionId] {
                    point.model = inferredModel
                } else if let inferredNearbyModel = nearbyModel(
                    forSessionId: sessionId,
                    lineIndex: lineIndex,
                    recentModels: recentModels
                ) {
                    point.model = inferredNearbyModel
                }
            } else if normalizedModel(point.model) == nil,
                      let inferredNearbyModel = nearbyModel(
                          forSessionId: nil,
                          lineIndex: lineIndex,
                          recentModels: recentModels
                      ) {
                point.model = inferredNearbyModel
            }

            points.append(point)
        }

        return points
    }

    private static func parseLine(_ rawLine: String) -> ParsedCodexLine? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false else {
            return nil
        }

        guard let data = line.data(using: .utf8) else {
            return nil
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }

        guard let object = jsonObject as? [String: Any] else {
            return nil
        }

        var kv: [FlatKeyValue] = []
        flatten(object, path: [], into: &kv)

        let timestamp = firstDate(
            in: kv,
            keyCandidates: [
                "timestamp", "ts", "time", "created_at", "createdat", "event_ts", "event_time", "started_at", "date",
            ]
        )

        let eventType = firstString(
            in: kv,
            keyCandidates: ["event_type", "eventtype", "type", "event"]
        )
        let isTokenCountEvent = normalizedEventType(eventType) == "token_count"

        let lastUsage = codexUsage(
            in: object,
            pathCandidates: [
                ["payload", "info", "last_token_usage"],
                ["info", "last_token_usage"],
                ["last_token_usage"],
            ]
        )
        let totalUsage = codexUsage(
            in: object,
            pathCandidates: [
                ["payload", "info", "total_token_usage"],
                ["info", "total_token_usage"],
                ["total_token_usage"],
            ]
        )

        let genericPromptTokens = firstInt(
            in: kv,
            keyCandidates: [
                "prompt_tokens", "prompttokens", "input_tokens", "inputtokens", "prompt_token_count", "input_token_count",
                "prompt_tokens_delta", "input_tokens_delta", "delta_prompt_tokens", "delta_input_tokens", "tokens_in",
            ]
        )

        let genericCompletionTokens = firstInt(
            in: kv,
            keyCandidates: [
                "completion_tokens", "completiontokens", "output_tokens", "outputtokens", "completion_token_count", "output_token_count",
                "completion_tokens_delta", "output_tokens_delta", "delta_completion_tokens", "delta_output_tokens", "tokens_out",
            ]
        )

        let genericTotalTokensDirect = firstInt(
            in: kv,
            keyCandidates: [
                "total_tokens", "totaltokens", "token_count", "tokencount", "usage_tokens", "total_token_count",
                "total_tokens_delta", "delta_total_tokens", "tokens_total",
            ]
        )

        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokensDirect: Int?
        if isTokenCountEvent {
            promptTokens = lastUsage?.promptTokens
            completionTokens = lastUsage?.completionTokens
            totalTokensDirect = lastUsage?.totalTokens
        } else {
            promptTokens = lastUsage?.promptTokens ?? genericPromptTokens
            completionTokens = lastUsage?.completionTokens ?? genericCompletionTokens
            totalTokensDirect = lastUsage?.totalTokens ?? genericTotalTokensDirect
        }

        let cumulativeTotalTokens = totalUsage?.totalTokens ?? firstInt(
            in: kv,
            keyCandidates: [
                "cumulative_total_tokens", "running_total_tokens", "total_tokens_cumulative", "aggregate_total_tokens",
            ]
        )

        let sessionId = firstString(
            in: kv,
            keyCandidates: ["session_id", "sessionid", "conversation_id", "conversationid", "thread_id", "threadid", "session"]
        )

        let model = firstString(
            in: kv,
            keyCandidates: ["model", "model_name", "modelname", "model_slug", "modelslug", "model_id", "modelid"]
        )

        return ParsedCodexLine(
            timestamp: timestamp,
            sessionId: sessionId,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokensDirect: totalTokensDirect,
            cumulativeTotalTokens: cumulativeTotalTokens
        )
    }

    private static func makePoint(
        from parsed: ParsedCodexLine,
        sourceFile: String,
        lastCumulativeTotalsBySession: inout [String: Int]
    ) -> Track2TimelinePoint? {
        let hasTokenData = parsed.promptTokens != nil
            || parsed.completionTokens != nil
            || parsed.totalTokensDirect != nil
            || parsed.cumulativeTotalTokens != nil
        guard hasTokenData else {
            return nil
        }

        guard let timestamp = parsed.timestamp else {
            return nil
        }

        let sessionKey = normalizedSessionKey(parsed.sessionId)
        let previousCumulativeTotal = lastCumulativeTotalsBySession[sessionKey]
        if let cumulativeTotalTokens = parsed.cumulativeTotalTokens {
            if let existing = previousCumulativeTotal {
                lastCumulativeTotalsBySession[sessionKey] = max(existing, cumulativeTotalTokens)
            } else {
                lastCumulativeTotalsBySession[sessionKey] = cumulativeTotalTokens
            }
        }

        var totalTokens: Int?
        if let totalTokensDirect = parsed.totalTokensDirect {
            totalTokens = totalTokensDirect
        } else if let promptTokens = parsed.promptTokens, let completionTokens = parsed.completionTokens {
            totalTokens = promptTokens + completionTokens
        } else if let cumulativeTotalTokens = parsed.cumulativeTotalTokens,
                  let previousCumulativeTotal,
                  cumulativeTotalTokens > previousCumulativeTotal
        {
            totalTokens = cumulativeTotalTokens - previousCumulativeTotal
        }

        let confidence: TrackConfidence
        if parsed.promptTokens != nil && parsed.completionTokens != nil && totalTokens != nil && parsed.sessionId != nil && parsed.model != nil {
            confidence = .medium
        } else {
            confidence = .low
        }

        return Track2TimelinePoint(
            provider: .codex,
            timestamp: timestamp,
            sessionId: parsed.sessionId,
            model: parsed.model,
            promptTokens: parsed.promptTokens,
            completionTokens: parsed.completionTokens,
            totalTokens: totalTokens,
            sourceFile: sourceFile,
            confidence: confidence,
            parserVersion: parserVersion
        )
    }
}

private struct ParsedCodexLine {
    var timestamp: Date?
    var sessionId: String?
    var model: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokensDirect: Int?
    var cumulativeTotalTokens: Int?
}

private struct CodexUsageSnapshot {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
}

private struct RecentModelContext {
    var sessionId: String?
    var model: String
    var lineIndex: Int
}

private func pushRecentModel(
    sessionId: String?,
    model: String,
    lineIndex: Int,
    into recentModels: inout [RecentModelContext]
) {
    recentModels.append(RecentModelContext(sessionId: sessionId, model: model, lineIndex: lineIndex))
    if recentModels.count > CodexTrack2PrimaryParser.nearbyModelHistoryLimit {
        recentModels.removeFirst(recentModels.count - CodexTrack2PrimaryParser.nearbyModelHistoryLimit)
    }
}

private func nearbyModel(
    forSessionId sessionId: String?,
    lineIndex: Int,
    recentModels: [RecentModelContext]
) -> String? {
    let nearby = recentModels.reversed().filter {
        lineIndex - $0.lineIndex <= CodexTrack2PrimaryParser.nearbyModelLineWindow
    }

    if let sessionId,
       let sameSession = nearby.first(where: { $0.sessionId == sessionId }) {
        return sameSession.model
    }

    if sessionId != nil,
       let sessionlessContext = nearby.first(where: { $0.sessionId == nil }) {
        return sessionlessContext.model
    }

    return nearby.first?.model
}

private func normalizedModel(_ model: String?) -> String? {
    guard let model else { return nil }
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func normalizedSessionKey(_ sessionId: String?) -> String {
    let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "__unknown_session__" : trimmed.lowercased()
}

private func normalizedEventType(_ eventType: String?) -> String {
    normalizeKey(eventType ?? "")
}

private func codexUsage(in object: [String: Any], pathCandidates: [[String]]) -> CodexUsageSnapshot? {
    for path in pathCandidates {
        guard let dict = nestedCodexDictionary(in: object, path: path) else {
            continue
        }

        let promptTokens = codexInt(
            in: dict,
            keyCandidates: ["input_tokens", "prompt_tokens", "tokens_in", "inputtokens", "prompttokens"]
        )
        let completionTokens = codexInt(
            in: dict,
            keyCandidates: ["output_tokens", "completion_tokens", "tokens_out", "outputtokens", "completiontokens"]
        )
        let totalTokens = codexInt(
            in: dict,
            keyCandidates: ["total_tokens", "token_count", "usage_tokens", "total_token_count"]
        )

        if promptTokens != nil || completionTokens != nil || totalTokens != nil {
            return CodexUsageSnapshot(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens
            )
        }
    }
    return nil
}

private func nestedCodexDictionary(in object: [String: Any], path: [String]) -> [String: Any]? {
    var cursor: Any = object
    for component in path {
        guard let dict = cursor as? [String: Any] else {
            return nil
        }
        let normalizedComponent = normalizeKey(component)
        guard let next = dict.first(where: { normalizeKey($0.key) == normalizedComponent })?.value else {
            return nil
        }
        cursor = next
    }
    return cursor as? [String: Any]
}

private func codexInt(in dict: [String: Any], keyCandidates: [String]) -> Int? {
    for candidate in keyCandidates {
        let normalizedCandidate = normalizeKey(candidate)
        guard let value = dict.first(where: { normalizeKey($0.key) == normalizedCandidate })?.value else {
            continue
        }
        if let intValue = asNonNegativeInt(value) {
            return intValue
        }
    }
    return nil
}

private struct FlatKeyValue {
    var key: String
    var value: Any
    var pathDepth: Int
}

private func flatten(_ value: Any, path: [String], into output: inout [FlatKeyValue]) {
    if let dict = value as? [String: Any] {
        for key in dict.keys.sorted() {
            guard let child = dict[key] else { continue }
            let normalizedKey = normalizeKey(key)
            output.append(FlatKeyValue(key: normalizedKey, value: child, pathDepth: path.count + 1))
            flatten(child, path: path + [normalizedKey], into: &output)
        }
        return
    }

    if let array = value as? [Any] {
        for item in array {
            flatten(item, path: path, into: &output)
        }
    }
}

private func firstString(in kv: [FlatKeyValue], keyCandidates: [String]) -> String? {
    for candidate in keyCandidates {
        let normalizedCandidate = normalizeKey(candidate)
        let matches = kv
            .filter { $0.key == normalizedCandidate }
            .sorted { lhs, rhs in
                if lhs.pathDepth != rhs.pathDepth {
                    return lhs.pathDepth < rhs.pathDepth
                }
                return String(describing: lhs.value) < String(describing: rhs.value)
            }

        for match in matches {
            if let s = asNonEmptyString(match.value) {
                return s
            }
        }
    }
    return nil
}

private func firstInt(in kv: [FlatKeyValue], keyCandidates: [String]) -> Int? {
    for candidate in keyCandidates {
        let normalizedCandidate = normalizeKey(candidate)
        let matches = kv
            .filter { $0.key == normalizedCandidate }
            .sorted { lhs, rhs in
                if lhs.pathDepth != rhs.pathDepth {
                    return lhs.pathDepth < rhs.pathDepth
                }
                return String(describing: lhs.value) < String(describing: rhs.value)
            }

        for match in matches {
            if let value = asNonNegativeInt(match.value) {
                return value
            }
        }
    }
    return nil
}

private func firstDate(in kv: [FlatKeyValue], keyCandidates: [String]) -> Date? {
    for candidate in keyCandidates {
        let normalizedCandidate = normalizeKey(candidate)
        let matches = kv
            .filter { $0.key == normalizedCandidate }
            .sorted { lhs, rhs in
                if lhs.pathDepth != rhs.pathDepth {
                    return lhs.pathDepth < rhs.pathDepth
                }
                return String(describing: lhs.value) < String(describing: rhs.value)
            }

        for match in matches {
            if let value = asDate(match.value) {
                return value
            }
        }
    }
    return nil
}

private func normalizeKey(_ key: String) -> String {
    let scalars = key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    return String(String.UnicodeScalarView(scalars)).lowercased()
}

private func asNonEmptyString(_ value: Any) -> String? {
    if let s = value as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return nil
}

private func asNonNegativeInt(_ value: Any) -> Int? {
    if let number = value as? NSNumber {
        let i = number.intValue
        return i >= 0 ? i : nil
    }

    if let s = value as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = Int(trimmed), i >= 0 {
            return i
        }
        if let d = Double(trimmed) {
            let i = Int(d)
            return i >= 0 ? i : nil
        }
    }
    return nil
}

private func asDate(_ value: Any) -> Date? {
    if let number = value as? NSNumber {
        return dateFromEpoch(number.doubleValue)
    }

    if let s = value as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if let d = Double(trimmed) {
            return dateFromEpoch(d)
        }

        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: trimmed) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    return nil
}

private func dateFromEpoch(_ value: Double) -> Date {
    if value > 10_000_000_000 {
        return Date(timeIntervalSince1970: value / 1000.0)
    }
    return Date(timeIntervalSince1970: value)
}
