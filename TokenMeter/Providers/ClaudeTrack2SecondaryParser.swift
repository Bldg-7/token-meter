import Foundation

struct ClaudeTrack2SecondaryParser {
    static let parserVersion = "claude_track2_secondary_v1"
    static let sourceMarker = "secondary_local"

    static func timelinePoints(from data: Data, sourceFile: String) -> [Track2TimelinePoint] {
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return timelinePoints(fromJSONL: text, sourceFile: sourceFile)
    }

    static func timelinePoints(fromJSONL text: String, sourceFile: String) -> [Track2TimelinePoint] {
        let taggedSourceFile = "\(sourceMarker):\(sourceFile)"
        var points: [Track2TimelinePoint] = []

        text.enumerateLines { line, _ in
            guard let point = parseLine(line, sourceFile: taggedSourceFile) else {
                return
            }
            points.append(point)
        }

        return deduplicate(points)
    }

    private static func parseLine(_ rawLine: String, sourceFile: String) -> Track2TimelinePoint? {
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

        let promptTokens = firstClaudeSecondaryInt(
            in: kv,
            keyCandidates: [
                "prompt_tokens", "prompttokens", "input_tokens", "inputtokens", "prompt_token_count", "input_token_count",
                "prompt_tokens_delta", "input_tokens_delta", "delta_prompt_tokens", "delta_input_tokens", "tokens_in",
            ]
        )

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

        let hasTokenData = promptTokens != nil || completionTokens != nil || totalTokensDirect != nil
        guard hasTokenData else {
            return nil
        }

        let totalTokens: Int?
        if let totalTokensDirect {
            totalTokens = totalTokensDirect
        } else if let promptTokens, let completionTokens {
            totalTokens = promptTokens + completionTokens
        } else {
            totalTokens = nil
        }

        let sessionId = firstClaudeSecondaryString(
            in: kv,
            keyCandidates: ["session_id", "sessionid", "conversation_id", "conversationid", "thread_id", "threadid", "session"]
        )

        let model = firstClaudeSecondaryString(
            in: kv,
            keyCandidates: ["model", "model_name", "modelname", "model_slug", "modelslug", "model_id", "modelid"]
        )

        let confidence: TrackConfidence
        if promptTokens != nil && completionTokens != nil && totalTokens != nil && sessionId != nil && model != nil {
            confidence = .medium
        } else {
            confidence = .low
        }

        return Track2TimelinePoint(
            provider: .claude,
            timestamp: timestamp,
            sessionId: sessionId,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            sourceFile: sourceFile,
            confidence: confidence,
            parserVersion: parserVersion
        )
    }

    private static func deduplicate(_ points: [Track2TimelinePoint]) -> [Track2TimelinePoint] {
        var seen: Set<String> = []
        var deduped: [Track2TimelinePoint] = []
        deduped.reserveCapacity(points.count)

        for point in points {
            let key = dedupKey(for: point)
            if seen.insert(key).inserted {
                deduped.append(point)
            }
        }

        return deduped
    }

    private static func dedupKey(for point: Track2TimelinePoint) -> String {
        let ts = Int64((point.timestamp.timeIntervalSince1970 * 1000.0).rounded())
        let session = (point.sessionId ?? "").lowercased()
        let model = (point.model ?? "").lowercased()
        let prompt = point.promptTokens.map(String.init) ?? "-"
        let completion = point.completionTokens.map(String.init) ?? "-"
        let total = point.totalTokens.map(String.init) ?? "-"
        return "\(ts)|\(session)|\(model)|\(prompt)|\(completion)|\(total)"
    }
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
