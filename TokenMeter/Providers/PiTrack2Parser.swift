import Foundation

/// Parses session logs written by the pi coding agent
/// (https://github.com/earendil-works/pi).
///
/// pi appends one JSONL file per session under
/// `~/.pi/agent/sessions/--<encoded cwd>--/<timestamp>_<session-id>.jsonl`.
/// Every assistant turn carries the model, the provider that served it and a
/// full token breakdown, which is everything a Track 2 point needs.
///
/// pi is a multi-provider client rather than a quota holder of its own: it
/// speaks each provider's native API directly, including over Claude Pro/Max
/// and ChatGPT subscription OAuth, so its turns draw down the very quota
/// TokenMeter already reports in Track 1. Points are therefore attributed to
/// the provider that owns the model — the same routing OpenCode rows get —
/// instead of pi being modelled as a third provider. pi exposes no quota
/// command or endpoint, so it contributes to Track 2 only.
struct PiTrack2Parser {
    static let parserVersion = "pi_track2_session_v1"
    static let sourceMarker = "pi_session"

    /// `/fork` and `/clone` copy the source session's entries verbatim into a
    /// new file — original `message.timestamp` values included — but write a
    /// fresh header stamped with the new session's creation time. Comparing
    /// each turn against that header is what keeps inherited history from
    /// being counted a second time. The tolerance only absorbs sub-second
    /// ordering between the header write and a first turn.
    private static let inheritedHistoryTolerance: TimeInterval = 1

    /// The `{"type":"session",...}` line that opens every session file.
    struct SessionHeader: Equatable {
        var sessionId: String?
        var startedAt: Date?

        init(sessionId: String? = nil, startedAt: Date? = nil) {
            self.sessionId = sessionId
            self.startedAt = startedAt
        }
    }

    static func sessionHeader(fromFirstLine line: String) -> SessionHeader? {
        guard let object = jsonObject(from: line),
              stringValue(object["type"]) == "session"
        else {
            return nil
        }

        return SessionHeader(
            sessionId: stringValue(object["id"]),
            startedAt: dateValue(object["timestamp"])
        )
    }

    static func timelinePoints(
        from data: Data,
        sourceFile: String,
        provider: ProviderId,
        header: SessionHeader?
    ) -> [Track2TimelinePoint] {
        // Decoded leniently: the incremental reader can hand over a buffer that
        // starts mid-character, because the 64KB context tail it prepends is
        // cut on a byte boundary. A strict decode would fail on the whole
        // buffer and drop every turn in it; a replacement character only
        // spoils the already-parsed partial line, which fails as JSON and is
        // skipped.
        let text = String(decoding: data, as: UTF8.self)
        return timelinePoints(fromJSONL: text, sourceFile: sourceFile, provider: provider, header: header)
    }

    static func timelinePoints(
        fromJSONL text: String,
        sourceFile: String,
        provider: ProviderId,
        header: SessionHeader?
    ) -> [Track2TimelinePoint] {
        let taggedSourceFile = "\(sourceMarker):\(sourceFile)"
        var points: [Track2TimelinePoint] = []

        text.enumerateLines { line, _ in
            guard let point = timelinePoint(
                fromLine: line,
                sourceFile: taggedSourceFile,
                provider: provider,
                header: header
            ) else {
                return
            }
            points.append(point)
        }

        return points
    }

    /// Routes a pi turn to the provider that owns the model. Models belonging
    /// to neither provider (Gemini, DeepSeek, local models) have no home in
    /// the two-provider Track 2 model and are dropped, exactly as unmatched
    /// OpenCode rows are.
    static func mappedProvider(model: String, providerHint: String?) -> ProviderId? {
        let lowercasedModel = model.lowercased()
        if lowercasedModel.contains("codex") || lowercasedModel.contains("gpt") {
            return .codex
        }
        if lowercasedModel.contains("claude") {
            return .claude
        }

        guard let hint = providerHint?.lowercased() else {
            return nil
        }
        if hint.contains("anthropic") {
            return .claude
        }
        if hint.contains("openai") {
            return .codex
        }
        return nil
    }

    private static func timelinePoint(
        fromLine rawLine: String,
        sourceFile: String,
        provider: ProviderId,
        header: SessionHeader?
    ) -> Track2TimelinePoint? {
        guard let object = jsonObject(from: rawLine),
              stringValue(object["type"]) == "message",
              let message = object["message"] as? [String: Any],
              stringValue(message["role"]) == "assistant",
              let usage = message["usage"] as? [String: Any]
        else {
            return nil
        }

        // `responseModel` names the model that actually answered when a router
        // rewrote the request (OpenRouter auto, for example), so it attributes
        // more accurately than the requested `model`.
        guard let model = stringValue(message["responseModel"]) ?? stringValue(message["model"]) else {
            return nil
        }

        guard let resolvedProvider = mappedProvider(model: model, providerHint: stringValue(message["provider"])),
              resolvedProvider == provider
        else {
            return nil
        }

        guard let timestamp = resolvedTimestamp(message: message, entry: object) else {
            return nil
        }

        if let startedAt = header?.startedAt,
           timestamp < startedAt.addingTimeInterval(-inheritedHistoryTolerance)
        {
            return nil
        }

        let inputTokens = intValue(usage["input"])
        let cacheReadTokens = intValue(usage["cacheRead"])
        let cacheWriteTokens = intValue(usage["cacheWrite"])
        let completionTokens = intValue(usage["output"])

        // `reasoning` is a documented subset of `output` and `cacheWrite1h` a
        // documented subset of `cacheWrite`; adding either double counts.
        var promptComponents: [Int] = []
        if let inputTokens {
            promptComponents.append(inputTokens)
        }
        if let cacheReadTokens {
            promptComponents.append(cacheReadTokens)
        }
        if let cacheWriteTokens {
            promptComponents.append(cacheWriteTokens)
        }
        let promptTokens = promptComponents.isEmpty ? nil : promptComponents.reduce(0, +)

        // pi defines totalTokens as input + output + cacheRead + cacheWrite,
        // so the computed sum agrees with it; the reported value is only a
        // fallback for turns with a partial breakdown.
        let totalTokens: Int?
        if let promptTokens, let completionTokens {
            totalTokens = promptTokens + completionTokens
        } else {
            totalTokens = intValue(usage["totalTokens"])
        }

        guard let resolvedTotalTokens = totalTokens, resolvedTotalTokens > 0 else {
            return nil
        }

        let sessionId = header?.sessionId

        let confidence: TrackConfidence
        if sessionId != nil, promptTokens != nil, completionTokens != nil {
            confidence = .medium
        } else {
            confidence = .low
        }

        return Track2TimelinePoint(
            provider: resolvedProvider,
            timestamp: timestamp,
            sessionId: sessionId,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: resolvedTotalTokens,
            sourceFile: sourceFile,
            confidence: confidence,
            parserVersion: parserVersion
        )
    }

    /// pi stamps assistant messages with a Unix millisecond timestamp; the
    /// enclosing entry carries an ISO-8601 string, used only as a fallback.
    private static func resolvedTimestamp(message: [String: Any], entry: [String: Any]) -> Date? {
        if let milliseconds = doubleValue(message["timestamp"]) {
            return date(fromUnixMilliseconds: milliseconds)
        }
        return dateValue(entry["timestamp"])
    }

    private static func jsonObject(from rawLine: String) -> [String: Any]? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false, let data = line.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            let doubleValue = number.doubleValue
            return doubleValue.isFinite ? doubleValue : nil
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    /// Range-checked: a corrupt log can carry a value no `Int` can hold, and
    /// converting that would trap rather than degrade.
    private static func intValue(_ value: Any?) -> Int? {
        guard let rawValue = doubleValue(value) else {
            return nil
        }
        let rounded = rawValue.rounded()
        guard rounded >= 0, let value = Int(exactly: rounded) else {
            return nil
        }
        return value
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let text = stringValue(value) {
            return isoDate(from: text)
        }
        if let milliseconds = doubleValue(value) {
            return date(fromUnixMilliseconds: milliseconds)
        }
        return nil
    }

    private static func date(fromUnixMilliseconds milliseconds: Double) -> Date? {
        guard milliseconds.isFinite, milliseconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1000.0)
    }

    private static func isoDate(from text: String) -> Date? {
        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractionalSeconds.date(from: text) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
