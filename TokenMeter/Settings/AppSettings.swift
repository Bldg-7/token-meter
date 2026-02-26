import Foundation

enum ProviderId: String, Codable {
    case codex
    case claude
}

enum CodexTrack1Source: String, Codable {
    case methodB = "method_b"
}

enum ClaudeTrack1Source: String, Codable {
    case methodB = "method_b"
    case methodC = "method_c"
}

struct CodexSettings: Codable, Equatable {
    var enabled: Bool
    var cliPathOverride: String?

    var track1Source: CodexTrack1Source

    init(enabled: Bool = true, cliPathOverride: String? = nil) {
        self.enabled = enabled
        self.cliPathOverride = cliPathOverride
        self.track1Source = .methodB
    }
}

struct ClaudeSettings: Codable, Equatable {
    var enabled: Bool
    var cliPathOverride: String?

    var track1Source: ClaudeTrack1Source
    var allowMethodC: Bool

    init(
        enabled: Bool = true,
        cliPathOverride: String? = nil,
        track1Source: ClaudeTrack1Source = .methodB,
        allowMethodC: Bool = false
    ) {
        self.enabled = enabled
        self.cliPathOverride = cliPathOverride
        self.track1Source = track1Source
        self.allowMethodC = allowMethodC
    }
}

enum AppLocaleSetting: Codable, Equatable {
    case system
    case fixed(String)

    private enum CodingKeys: String, CodingKey { case mode, value }
    private enum Mode: String, Codable { case system, fixed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        switch mode {
        case .system:
            self = .system
        case .fixed:
            let value = try container.decode(String.self, forKey: .value)
            self = .fixed(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system:
            try container.encode(Mode.system, forKey: .mode)
        case .fixed(let value):
            try container.encode(Mode.fixed, forKey: .mode)
            try container.encode(value, forKey: .value)
        }
    }
}

enum Track2WidgetTimeScale: String, Codable, Equatable, CaseIterable, Identifiable {
    case hours24 = "24h"
    case hours12 = "12h"
    case hours6 = "6h"
    case hours3 = "3h"
    case hour1 = "1h"

    var id: String { rawValue }

    var windowSeconds: TimeInterval {
        switch self {
        case .hours24:
            return 24 * 60 * 60
        case .hours12:
            return 12 * 60 * 60
        case .hours6:
            return 6 * 60 * 60
        case .hours3:
            return 3 * 60 * 60
        case .hour1:
            return 1 * 60 * 60
        }
    }
}

struct AppSettings: Codable, Equatable {
    var codex: CodexSettings
    var claude: ClaudeSettings

    var locale: AppLocaleSetting
    var refreshIntervalSec: Int
    var widgetTrack2TimeScale: Track2WidgetTimeScale

    private enum CodingKeys: String, CodingKey {
        case codex
        case claude
        case locale
        case refreshIntervalSec
        case widgetTrack2TimeScale
    }

    init(
        codex: CodexSettings = CodexSettings(),
        claude: ClaudeSettings = ClaudeSettings(),
        locale: AppLocaleSetting = .system,
        refreshIntervalSec: Int = 60,
        widgetTrack2TimeScale: Track2WidgetTimeScale = .hours24
    ) {
        self.codex = codex
        self.claude = claude
        self.locale = locale
        self.refreshIntervalSec = refreshIntervalSec
        self.widgetTrack2TimeScale = widgetTrack2TimeScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codex = try container.decodeIfPresent(CodexSettings.self, forKey: .codex) ?? CodexSettings()
        claude = try container.decodeIfPresent(ClaudeSettings.self, forKey: .claude) ?? ClaudeSettings()
        locale = try container.decodeIfPresent(AppLocaleSetting.self, forKey: .locale) ?? .system
        refreshIntervalSec = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSec) ?? 60
        widgetTrack2TimeScale = try container.decodeIfPresent(Track2WidgetTimeScale.self, forKey: .widgetTrack2TimeScale) ?? .hours24
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(codex, forKey: .codex)
        try container.encode(claude, forKey: .claude)
        try container.encode(locale, forKey: .locale)
        try container.encode(refreshIntervalSec, forKey: .refreshIntervalSec)
        try container.encode(widgetTrack2TimeScale, forKey: .widgetTrack2TimeScale)
    }
}
