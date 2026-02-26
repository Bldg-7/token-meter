import Foundation

enum DiagnosticsRedactionKind: String, Sendable {
    case bearer
    case cookie
    case session
    case token
    case apiKey
    case password
    case secret
    case unknown
}

struct DiagnosticsRedactor {
    private static let sensitiveKeyKinds: [(key: String, kind: DiagnosticsRedactionKind)] = [
        ("authorization", .bearer),
        ("proxy-authorization", .bearer),
        ("cookie", .cookie),
        ("set-cookie", .cookie),
        ("x-api-key", .apiKey),
        ("api-key", .apiKey),
        ("apikey", .apiKey),
        ("api_key", .apiKey),
        ("token", .token),
        ("access_token", .token),
        ("refresh_token", .token),
        ("id_token", .token),
        ("session", .session),
        ("sessionid", .session),
        ("sid", .session),
        ("password", .password),
        ("passwd", .password),
        ("secret", .secret),
        ("client_secret", .secret),
    ]

    private let authorizationBearerRegex: NSRegularExpression
    private let bearerTokenRegex: NSRegularExpression
    private let queryParamRegex: NSRegularExpression
    private let cookieHeaderRegex: NSRegularExpression

    init() {
        self.authorizationBearerRegex = DiagnosticsRedactor.makeRegex("(?i)(\\bAuthorization\\s*:\\s*Bearer\\s+)(\\S+)")
        self.bearerTokenRegex = DiagnosticsRedactor.makeRegex("(?i)(\\bBearer\\s+)([A-Za-z0-9\\-._~+/]+=*)")
        self.queryParamRegex = DiagnosticsRedactor.makeRegex("(?i)([?&])(token|access_token|refresh_token|id_token|api_key|apikey|key|session|sid|password)=([^&#\\s]+)")
        self.cookieHeaderRegex = DiagnosticsRedactor.makeRegex("(?i)\\b(Set-Cookie|Cookie)\\s*:\\s*([^\\r\\n]+)")
    }

    func redactMessage(_ message: String) -> String {
        if message.isEmpty { return message }

        let lower = message.lowercased()
        if lower.contains("bearer") == false,
           lower.contains("authorization") == false,
           lower.contains("cookie") == false,
           lower.contains("token") == false,
           lower.contains("api_key") == false,
           lower.contains("apikey") == false,
           lower.contains("session") == false,
           message.contains("?") == false,
           message.contains("&") == false {
            return message
        }

        var out = message
        out = replaceCapturedGroup(in: out, regex: authorizationBearerRegex, groupIndex: 2, kind: .bearer)
        out = replaceCapturedGroup(in: out, regex: bearerTokenRegex, groupIndex: 2, kind: .bearer)
        out = replaceCapturedGroup(in: out, regex: queryParamRegex, groupIndex: 3) { value, fullMatch in
            let name = (fullMatch.group(at: 2, in: out) ?? "").lowercased()
            let kind: DiagnosticsRedactionKind
            switch name {
            case "password":
                kind = .password
            case "api_key", "apikey", "key":
                kind = .apiKey
            case "session", "sid":
                kind = .session
            default:
                kind = .token
            }
            return tag(kind: kind, secret: value)
        }

        out = redactCookieHeaders(in: out)
        return out
    }

    func redactFields(_ fields: [String: DiagnosticsValue]) -> [String: DiagnosticsValue] {
        if fields.isEmpty { return fields }
        var out: [String: DiagnosticsValue] = [:]
        out.reserveCapacity(fields.count)

        for (k, v) in fields {
            let kind = DiagnosticsRedactor.kindForSensitiveKey(k)
            if let kind {
                out[k] = .string(tag(kind: kind, secret: stringified(v)))
            } else {
                out[k] = redactValue(v)
            }
        }
        return out
    }

    private func redactValue(_ value: DiagnosticsValue) -> DiagnosticsValue {
        switch value {
        case .string(let s):
            return .string(redactMessage(s))
        case .array(let arr):
            return .array(arr.map { redactValue($0) })
        case .object(let obj):
            var out: [String: DiagnosticsValue] = [:]
            out.reserveCapacity(obj.count)
            for (k, v) in obj {
                let kind = DiagnosticsRedactor.kindForSensitiveKey(k)
                if let kind {
                    out[k] = .string(tag(kind: kind, secret: stringified(v)))
                } else {
                    out[k] = redactValue(v)
                }
            }
            return .object(out)
        case .int, .double, .bool, .null:
            return value
        }
    }

    private static func kindForSensitiveKey(_ key: String) -> DiagnosticsRedactionKind? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for pair in sensitiveKeyKinds {
            if normalized == pair.key {
                return pair.kind
            }
        }
        return nil
    }

    private func redactCookieHeaders(in message: String) -> String {
        let ns = message as NSString
        let matches = cookieHeaderRegex.matches(in: message, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return message }

        var out = message
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let valueRange = match.range(at: 2)
            guard let r = Range(valueRange, in: out) else { continue }
            let headerValue = String(out[r])
            let redactedValue = redactCookieHeaderValue(headerValue)
            out.replaceSubrange(r, with: redactedValue)
        }
        return out
    }

    private func redactCookieHeaderValue(_ value: String) -> String {
        let sensitiveCookieNames: Set<String> = [
            "session", "sessionid", "sid", "jwt", "token", "auth", "oauth", "csrf",
        ]

        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        var outParts: [String] = []
        outParts.reserveCapacity(parts.count)

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else {
                outParts.append(String(part))
                continue
            }
            let name = trimmed[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = trimmed.index(after: eq)
            let cookieValue = String(trimmed[valueStart...])

            if sensitiveCookieNames.contains(name) {
                let redacted = tag(kind: .cookie, secret: cookieValue)
                let prefix = trimmed[..<valueStart]
                outParts.append(String(prefix) + redacted)
            } else {
                outParts.append(String(part))
            }
        }

        return outParts.joined(separator: ";")
    }

    private func stringified(_ value: DiagnosticsValue) -> String {
        switch value {
        case .string(let s):
            return s
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .array(let arr):
            return "[" + arr.map(stringified).joined(separator: ",") + "]"
        case .object(let obj):
            let pairs = obj.keys.sorted().map { key in
                let v = obj[key].map(stringified) ?? "null"
                return "\(key)=\(v)"
            }
            return "{" + pairs.joined(separator: ",") + "}"
        case .null:
            return "null"
        }
    }

    private func tag(kind: DiagnosticsRedactionKind, secret: String) -> String {
        let h = fnv1a64(secret)
        let hex = String(format: "%08x", UInt32(truncatingIfNeeded: h))
        return "<redacted:\(kind.rawValue):\(hex)>"
    }

    private func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211

        for b in string.utf8 {
            hash ^= UInt64(b)
            hash &*= prime
        }
        return hash
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        return try! NSRegularExpression(pattern: pattern)
    }

    private func replaceCapturedGroup(
        in string: String,
        regex: NSRegularExpression,
        groupIndex: Int,
        kind: DiagnosticsRedactionKind
    ) -> String {
        replaceCapturedGroup(in: string, regex: regex, groupIndex: groupIndex) { value, _ in
            tag(kind: kind, secret: value)
        }
    }

    private func replaceCapturedGroup(
        in string: String,
        regex: NSRegularExpression,
        groupIndex: Int,
        replacer: (_ captured: String, _ match: DiagnosticsRegexMatch) -> String
    ) -> String {
        let ns = string as NSString
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return string }

        var out = string
        for match in matches.reversed() {
            guard match.numberOfRanges > groupIndex else { continue }
            let r = match.range(at: groupIndex)
            guard let rr = Range(r, in: out) else { continue }
            let captured = String(out[rr])
            let replacement = replacer(captured, DiagnosticsRegexMatch(match: match))
            out.replaceSubrange(rr, with: replacement)
        }
        return out
    }
}

private struct DiagnosticsRegexMatch {
    fileprivate let match: NSTextCheckingResult

    func group(at index: Int, in string: String) -> String? {
        let ns = string as NSString
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }
}
