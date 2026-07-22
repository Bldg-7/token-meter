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

    /// GPT tier variants (GPT-5.6 era) that identify distinct models the way
    /// Opus/Sonnet/Haiku do for Claude; suffixes like "-codex" or "-turbo"
    /// stay merged into the base family.
    private static let gptVariants: [(token: String, label: String)] = [
        ("sol", "Sol"),
        ("terra", "Terra"),
        ("luna", "Luna"),
    ]

    private static func codexFamily(from model: String) -> String {
        if model.contains("gpt-3.5") {
            return "GPT 3.5"
        }

        if let version = majorMinorVersion(after: "gpt-", in: model) {
            if let variant = gptVariant(in: model) {
                return "GPT \(version) \(variant)"
            }
            return "GPT \(version)"
        }

        if model.contains("gpt") {
            return "GPT"
        }

        return "Unknown"
    }

    private static func gptVariant(in model: String) -> String? {
        let tokens = Set(model.split(whereSeparator: { $0.isLetter == false }).map(String.init))
        for variant in gptVariants where tokens.contains(variant.token) {
            return variant.label
        }
        return nil
    }

    private static func claudeFamily(from model: String) -> String {
        if let version = majorMinorVersion(after: "claude-fable-", in: model) {
            return "Fable \(version)"
        }
        if model.contains("claude-fable") {
            return "Fable"
        }

        if let version = majorMinorVersion(after: "claude-mythos-", in: model) {
            return "Mythos \(version)"
        }
        if model.contains("claude-mythos") {
            return "Mythos"
        }

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

        // Version components are 1-2 digits; longer chunks are date stamps
        // (e.g. claude-fable-5-20260601) and must not become a minor version.
        let components = token
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { $0.isEmpty == false && $0.count <= 2 }

        guard components.isEmpty == false else {
            return nil
        }

        let majorMinor = Array(components.prefix(2))
        return majorMinor.joined(separator: ".")
    }
}
