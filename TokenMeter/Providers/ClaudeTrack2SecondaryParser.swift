import Foundation

struct ClaudeTrack2SecondaryParser {
    static let parserVersion = "claude_track2_secondary_v2"
    static let sourceMarker = "secondary_local"

    static func timelinePoints(from data: Data, sourceFile: String) -> [Track2TimelinePoint] {
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return timelinePoints(fromJSONL: text, sourceFile: sourceFile)
    }

    static func timelinePoints(fromJSONL text: String, sourceFile: String) -> [Track2TimelinePoint] {
        let taggedSourceFile = "\(sourceMarker):\(sourceFile)"
        var parsedLines: [ParsedClaudeSecondaryLine] = []

        text.enumerateLines { line, _ in
            guard let parsedLine = parseLine(line) else {
                return
            }
            parsedLines.append(parsedLine)
        }

        return deduplicate(parsedLines).compactMap { parsedLine in
            makePoint(from: parsedLine, sourceFile: taggedSourceFile)
        }
    }

    private static func parseLine(_ rawLine: String) -> ParsedClaudeSecondaryLine? {
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

        var kv: [ClaudeSecondaryFlatKeyValue] = []
        flattenClaudeSecondary(object, path: [], into: &kv)

        guard let timestamp = firstClaudeSecondaryDate(
            in: kv,
            keyCandidates: [
                "timestamp", "ts", "time", "created_at", "createdat", "event_ts", "event_time", "started_at", "date",
            ]
        ) else {
            return nil
        }

        let inputTokens = firstClaudeSecondaryInt(
            in: kv,
            keyCandidates: [
                "prompt_tokens", "prompttokens", "input_tokens", "inputtokens", "prompt_token_count", "input_token_count",
                "prompt_tokens_delta", "input_tokens_delta", "delta_prompt_tokens", "delta_input_tokens", "tokens_in",
            ]
        )

        let cacheReadTokens = firstClaudeSecondaryInt(
            in: kv,
            keyCandidates: [
                "cache_read_input_tokens", "cache_read_tokens", "cached_input_tokens",
            ]
        )

        var cacheCreationTokens = firstClaudeSecondaryInt(
            in: kv,
            keyCandidates: [
                "cache_creation_input_tokens", "cache_creation_tokens", "cache_write_input_tokens", "cached_creation_input_tokens",
            ]
        )

        if cacheCreationTokens == nil {
            cacheCreationTokens = sumClaudeSecondaryInts(
                in: kv,
                keyCandidates: ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"]
            )
        }

        let completionTokens = firstClaudeSecondaryInt(
            in: kv,
            keyCandidates: [
                "completion_tokens", "completiontokens", "output_tokens", "outputtokens", "completion_token_count", "output_token_count",
                "completion_tokens_delta", "output_tokens_delta", "delta_completion_tokens", "delta_output_tokens", "tokens_out",
            ]
        )

        let totalTokensDirect = firstClaudeSecondaryInt(
            in: kv,
            keyCandidates: [
                "total_tokens", "totaltokens", "token_count", "tokencount", "usage_tokens", "total_token_count",
                "total_tokens_delta", "delta_total_tokens", "tokens_total", "cumulative_total_tokens",
                "running_total_tokens", "total_tokens_cumulative", "aggregate_total_tokens",
            ]
        )

        var promptComponents: [Int] = []
        if let inputTokens {
            promptComponents.append(inputTokens)
        }
        if let cacheReadTokens {
            promptComponents.append(cacheReadTokens)
        }
        if let cacheCreationTokens {
            promptComponents.append(cacheCreationTokens)
        }
        let promptTokens = promptComponents.isEmpty ? nil : promptComponents.reduce(0, +)

        let hasTokenData = promptTokens != nil || completionTokens != nil || totalTokensDirect != nil
        guard hasTokenData else {
            return nil
        }

        let sessionId = firstClaudeSecondaryString(
            in: kv,
            keyCandidates: ["session_id", "sessionid", "conversation_id", "conversationid", "thread_id", "threadid", "session"]
        )

        let model = firstClaudeSecondaryString(
            in: kv,
            keyCandidates: ["model", "model_name", "modelname", "model_slug", "modelslug", "model_id", "modelid"]
        )

        let requestId = firstClaudeSecondaryString(
            in: kv,
            keyCandidates: ["request_id", "requestid"]
        )

        let messageId = nestedClaudeSecondaryString(in: object, path: ["message", "id"])

        return ParsedClaudeSecondaryLine(
            timestamp: timestamp,
            sessionId: sessionId,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokensDirect: totalTokensDirect,
            requestId: requestId,
            messageId: messageId
        )
    }

    private static func makePoint(from parsed: ParsedClaudeSecondaryLine, sourceFile: String) -> Track2TimelinePoint? {
        let totalTokens: Int?
        if let totalTokensDirect = parsed.totalTokensDirect {
            totalTokens = totalTokensDirect
        } else if let promptTokens = parsed.promptTokens, let completionTokens = parsed.completionTokens {
            totalTokens = promptTokens + completionTokens
        } else {
            totalTokens = nil
        }

        let confidence: TrackConfidence
        if parsed.promptTokens != nil,
           parsed.completionTokens != nil,
           totalTokens != nil,
           parsed.sessionId != nil,
           parsed.model != nil
        {
            confidence = .medium
        } else {
            confidence = .low
        }

        return Track2TimelinePoint(
            provider: .claude,
            timestamp: parsed.timestamp,
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

    private static func deduplicate(_ parsedLines: [ParsedClaudeSecondaryLine]) -> [ParsedClaudeSecondaryLine] {
        var byIdentity: [String: ParsedClaudeSecondaryLine] = [:]
        var identityOrder: [String] = []
        var passthrough: [ParsedClaudeSecondaryLine] = []

        for parsedLine in parsedLines {
            guard let identityKey = identityKey(for: parsedLine) else {
                passthrough.append(parsedLine)
                continue
            }

            if let existing = byIdentity[identityKey] {
                if shouldPrefer(parsedLine, over: existing) {
                    byIdentity[identityKey] = parsedLine
                }
            } else {
                byIdentity[identityKey] = parsedLine
                identityOrder.append(identityKey)
            }
        }

        var merged: [ParsedClaudeSecondaryLine] = []
        merged.reserveCapacity(parsedLines.count)
        for identityKey in identityOrder {
            if let parsedLine = byIdentity[identityKey] {
                merged.append(parsedLine)
            }
        }
        merged.append(contentsOf: passthrough)

        var seen: Set<String> = []
        var deduped: [ParsedClaudeSecondaryLine] = []
        deduped.reserveCapacity(merged.count)
        for parsedLine in merged {
            let key = dedupKey(for: parsedLine)
            if seen.insert(key).inserted {
                deduped.append(parsedLine)
            }
        }

        return deduped
    }

    private static func identityKey(for parsedLine: ParsedClaudeSecondaryLine) -> String? {
        if let requestId = normalizedClaudeSecondaryIdentity(parsedLine.requestId) {
            return "request:\(requestId)"
        }
        if let messageId = normalizedClaudeSecondaryIdentity(parsedLine.messageId) {
            let session = normalizedClaudeSecondaryIdentity(parsedLine.sessionId) ?? "__unknown_session__"
            return "message:\(session)|\(messageId)"
        }
        return nil
    }

    private static func shouldPrefer(_ candidate: ParsedClaudeSecondaryLine, over existing: ParsedClaudeSecondaryLine) -> Bool {
        let candidateTotal = effectiveTotalTokens(for: candidate) ?? -1
        let existingTotal = effectiveTotalTokens(for: existing) ?? -1
        if candidateTotal != existingTotal {
            return candidateTotal > existingTotal
        }

        if candidate.timestamp != existing.timestamp {
            return candidate.timestamp > existing.timestamp
        }

        return completenessScore(for: candidate) > completenessScore(for: existing)
    }

    private static func effectiveTotalTokens(for parsedLine: ParsedClaudeSecondaryLine) -> Int? {
        if let totalTokensDirect = parsedLine.totalTokensDirect {
            return totalTokensDirect
        }
        if let promptTokens = parsedLine.promptTokens, let completionTokens = parsedLine.completionTokens {
            return promptTokens + completionTokens
        }
        return nil
    }

    private static func completenessScore(for parsedLine: ParsedClaudeSecondaryLine) -> Int {
        var score = 0
        if parsedLine.promptTokens != nil { score += 1 }
        if parsedLine.completionTokens != nil { score += 1 }
        if parsedLine.totalTokensDirect != nil { score += 1 }
        if parsedLine.sessionId != nil { score += 1 }
        if parsedLine.model != nil { score += 1 }
        return score
    }

    private static func dedupKey(for parsedLine: ParsedClaudeSecondaryLine) -> String {
        let ts = Int64((parsedLine.timestamp.timeIntervalSince1970 * 1000.0).rounded())
        let session = (parsedLine.sessionId ?? "").lowercased()
        let model = (parsedLine.model ?? "").lowercased()
        let prompt = parsedLine.promptTokens.map(String.init) ?? "-"
        let completion = parsedLine.completionTokens.map(String.init) ?? "-"
        let total = effectiveTotalTokens(for: parsedLine).map(String.init) ?? "-"
        return "\(ts)|\(session)|\(model)|\(prompt)|\(completion)|\(total)"
    }
}

private struct ParsedClaudeSecondaryLine {
    var timestamp: Date
    var sessionId: String?
    var model: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokensDirect: Int?
    var requestId: String?
    var messageId: String?
}

private struct ClaudeSecondaryFlatKeyValue {
    var key: String
    var value: Any
    var pathDepth: Int
}

private func flattenClaudeSecondary(_ value: Any, path: [String], into output: inout [ClaudeSecondaryFlatKeyValue]) {
    if let dict = value as? [String: Any] {
        for key in dict.keys.sorted() {
            guard let child = dict[key] else { continue }
            let normalizedKey = normalizeClaudeSecondaryKey(key)
            output.append(ClaudeSecondaryFlatKeyValue(key: normalizedKey, value: child, pathDepth: path.count + 1))
            flattenClaudeSecondary(child, path: path + [normalizedKey], into: &output)
        }
        return
    }

    if let array = value as? [Any] {
        for item in array {
            flattenClaudeSecondary(item, path: path, into: &output)
        }
    }
}

private func firstClaudeSecondaryString(in kv: [ClaudeSecondaryFlatKeyValue], keyCandidates: [String]) -> String? {
    for candidate in keyCandidates {
        let normalizedCandidate = normalizeClaudeSecondaryKey(candidate)
        let matches = kv
            .filter { $0.key == normalizedCandidate }
            .sorted { lhs, rhs in
                if lhs.pathDepth != rhs.pathDepth {
                    return lhs.pathDepth < rhs.pathDepth
                }
                return String(describing: lhs.value) < String(describing: rhs.value)
            }

        for match in matches {
            if let s = asClaudeSecondaryNonEmptyString(match.value) {
                return s
            }
        }
    }
    return nil
}

private func firstClaudeSecondaryInt(in kv: [ClaudeSecondaryFlatKeyValue], keyCandidates: [String]) -> Int? {
    for candidate in keyCandidates {
        let normalizedCandidate = normalizeClaudeSecondaryKey(candidate)
        let matches = kv
            .filter { $0.key == normalizedCandidate }
            .sorted { lhs, rhs in
                if lhs.pathDepth != rhs.pathDepth {
                    return lhs.pathDepth < rhs.pathDepth
                }
                return String(describing: lhs.value) < String(describing: rhs.value)
            }

        for match in matches {
            if let value = asClaudeSecondaryNonNegativeInt(match.value) {
                return value
            }
        }
    }
    return nil
}

private func sumClaudeSecondaryInts(in kv: [ClaudeSecondaryFlatKeyValue], keyCandidates: [String]) -> Int? {
    var total = 0
    var matched = false

    for candidate in keyCandidates {
        let normalizedCandidate = normalizeClaudeSecondaryKey(candidate)
        let matches = kv.filter { $0.key == normalizedCandidate }
        for match in matches {
            if let value = asClaudeSecondaryNonNegativeInt(match.value) {
                total += value
                matched = true
            }
        }
    }

    return matched ? total : nil
}

private func firstClaudeSecondaryDate(in kv: [ClaudeSecondaryFlatKeyValue], keyCandidates: [String]) -> Date? {
    for candidate in keyCandidates {
        let normalizedCandidate = normalizeClaudeSecondaryKey(candidate)
        let matches = kv
            .filter { $0.key == normalizedCandidate }
            .sorted { lhs, rhs in
                if lhs.pathDepth != rhs.pathDepth {
                    return lhs.pathDepth < rhs.pathDepth
                }
                return String(describing: lhs.value) < String(describing: rhs.value)
            }

        for match in matches {
            if let value = asClaudeSecondaryDate(match.value) {
                return value
            }
        }
    }
    return nil
}

private func nestedClaudeSecondaryString(in object: [String: Any], path: [String]) -> String? {
    var cursor: Any = object
    for component in path {
        guard let dict = cursor as? [String: Any] else {
            return nil
        }
        let normalizedComponent = normalizeClaudeSecondaryKey(component)
        guard let next = dict.first(where: { normalizeClaudeSecondaryKey($0.key) == normalizedComponent })?.value else {
            return nil
        }
        cursor = next
    }
    return asClaudeSecondaryNonEmptyString(cursor)
}

private func normalizedClaudeSecondaryIdentity(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    return trimmed.lowercased()
}

private func normalizeClaudeSecondaryKey(_ key: String) -> String {
    let scalars = key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    return String(String.UnicodeScalarView(scalars)).lowercased()
}

private func asClaudeSecondaryNonEmptyString(_ value: Any) -> String? {
    if let s = value as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    return nil
}

private func asClaudeSecondaryNonNegativeInt(_ value: Any) -> Int? {
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

private func asClaudeSecondaryDate(_ value: Any) -> Date? {
    if let number = value as? NSNumber {
        return claudeSecondaryDateFromEpoch(number.doubleValue)
    }

    if let s = value as? String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if let d = Double(trimmed) {
            return claudeSecondaryDateFromEpoch(d)
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

private func claudeSecondaryDateFromEpoch(_ value: Double) -> Date {
    if value > 10_000_000_000 {
        return Date(timeIntervalSince1970: value / 1000.0)
    }
    return Date(timeIntervalSince1970: value)
}
