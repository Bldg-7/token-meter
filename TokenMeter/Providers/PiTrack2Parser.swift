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
        return timelinePoints(
            fromJSONL: text,
            sourceFile: sourceFile,
            provider: provider,
            header: header
        )
    }

    static func timelinePoints(
        fromJSONL text: String,
        sourceFile: String,
        provider: ProviderId,
        header: SessionHeader?
    ) -> [Track2TimelinePoint] {
        let taggedSourceFile = "\(sourceMarker):\(sourceFile)"
        var points: [Track2TimelinePoint] = []
        // Deliberately scoped to this buffer rather than carried across cycles.
        // A summarization entry names no model, so it is billed to whatever the
        // session was last seen running — and if that were carried in, the same
        // entry would be attributed differently depending on how much history
        // the parse window happened to contain, which produces a second,
        // differently-keyed point every time the context tail is re-read.
        var windowModel: String?

        text.enumerateLines { line, _ in
            guard let object = jsonObject(from: line),
                  let entryType = stringValue(object["type"])
            else {
                return
            }

            switch entryType {
            case "message":
                guard let message = object["message"] as? [String: Any],
                      stringValue(message["role"]) == "assistant"
                else {
                    return
                }

                // `responseModel` names the model that actually answered when a
                // router rewrote the request (OpenRouter auto, for example), so
                // it attributes more accurately than the requested `model`.
                guard let model = stringValue(message["responseModel"]) ?? stringValue(message["model"]) else {
                    return
                }
                windowModel = model

                guard let usage = message["usage"] as? [String: Any],
                      let timestamp = entryTimestamp(message: message, entry: object),
                      isOwnedBySession(timestamp: timestamp, header: header),
                      let point = makePoint(
                          usage: usage,
                          model: model,
                          providerHint: stringValue(message["provider"]),
                          timestamp: timestamp,
                          provider: provider,
                          sessionId: header?.sessionId,
                          sourceFile: taggedSourceFile
                      )
                else {
                    return
                }
                points.append(point)

            case "model_change":
                if let model = stringValue(object["modelId"]) ?? stringValue(object["model"]) {
                    windowModel = model
                }

            // Summarizing the context is itself an LLM call, and an expensive
            // one — it reads the whole conversation. pi counts it in the
            // session totals and records its usage at the entry level, with no
            // message wrapper and no model of its own, so it is billed to the
            // model this buffer last saw the session running.
            case "compaction", "branch_summary":
                guard let usage = object["usage"] as? [String: Any],
                      let timestamp = entryTimestamp(message: nil, entry: object),
                      isOwnedBySession(timestamp: timestamp, header: header),
                      let point = makePoint(
                          usage: usage,
                          model: windowModel,
                          providerHint: nil,
                          timestamp: timestamp,
                          provider: provider,
                          sessionId: header?.sessionId,
                          sourceFile: taggedSourceFile
                      )
                else {
                    return
                }
                points.append(point)

            default:
                return
            }
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

    /// `/fork` and `/clone` copy prior entries verbatim into a new file while
    /// stamping a fresh header, so anything older than the header is history
    /// this session inherited rather than spent.
    private static func isOwnedBySession(timestamp: Date, header: SessionHeader?) -> Bool {
        guard let startedAt = header?.startedAt else {
            return true
        }
        return timestamp >= startedAt.addingTimeInterval(-inheritedHistoryTolerance)
    }

    private static func makePoint(
        usage: [String: Any],
        model: String?,
        providerHint: String?,
        timestamp: Date,
        provider: ProviderId,
        sessionId: String?,
        sourceFile: String
    ) -> Track2TimelinePoint? {
        guard let model,
              let resolvedProvider = mappedProvider(model: model, providerHint: providerHint),
              resolvedProvider == provider
        else {
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
    private static func entryTimestamp(message: [String: Any]?, entry: [String: Any]) -> Date? {
        if let message, let milliseconds = doubleValue(message["timestamp"]) {
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
