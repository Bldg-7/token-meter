import Foundation

enum Track2ModelClassifier {
    static func familyLabel(provider: ProviderId, model: String?) -> String {
        guard let model = normalizedModel(model) else {
            return "Unknown"
        }

        let lower = model.lowercased()
        switch provider {
        case .codex:
            return codexFamily(from: lower)
        case .claude:
            return claudeFamily(from: lower)
        }
    }

    private static func normalizedModel(_ model: String?) -> String? {
        guard let model else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func codexFamily(from model: String) -> String {
        if model.contains("gpt-3.5") {
            return "GPT 3.5"
        }

        if let version = majorMinorVersion(after: "gpt-", in: model) {
            return "GPT \(version)"
        }

        if model.contains("gpt") {
            return "GPT"
        }

        return "Unknown"
    }

    private static func claudeFamily(from model: String) -> String {
        if let version = majorMinorVersion(after: "claude-opus-", in: model) {
            return "Opus \(version)"
        }
        if model.contains("claude-opus") {
            return "Opus"
        }

        if let version = majorMinorVersion(after: "claude-sonnet-", in: model) {
            return "Sonnet \(version)"
        }
        if model.contains("claude-sonnet") {
            return "Sonnet"
        }

        if let version = majorMinorVersion(after: "claude-haiku-", in: model) {
            return "Haiku \(version)"
        }
        if model.contains("claude-haiku") {
            return "Haiku"
        }

        if model.contains("claude") {
            return "Claude"
        }

        return "Unknown"
    }

    private static func majorMinorVersion(after prefix: String, in value: String) -> String? {
        guard let range = value.range(of: prefix) else {
            return nil
        }

        let suffix = value[range.upperBound...]
        var token = ""
        var hasStarted = false

        for character in suffix {
            if character.isNumber {
                token.append(character)
                hasStarted = true
                continue
            }

            if hasStarted, character == "." || character == "-" || character == "_" {
                token.append(character)
                continue
            }

            if hasStarted {
                break
            }

            if character.isWhitespace {
                continue
            }

            break
        }

        guard hasStarted else {
            return nil
        }

        let components = token
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { $0.isEmpty == false }

        guard components.isEmpty == false else {
            return nil
        }

        let majorMinor = Array(components.prefix(2))
        return majorMinor.joined(separator: ".")
    }
}
