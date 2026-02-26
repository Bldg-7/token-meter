import Foundation

actor SettingsStore {
    static let shared = SettingsStore()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let settingsURLOverride: URL?

    private var cached: AppSettings?

    init(settingsURLOverride: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()

        self.settingsURLOverride = settingsURLOverride
    }

    func load() throws -> AppSettings {
        if let cached { return cached }

        let url = try settingsURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            let settings = AppSettings()
            self.cached = settings
            return settings
        }

        let data = try Data(contentsOf: url)
        let settings = try decoder.decode(AppSettings.self, from: data)

        try validate(settings)

        self.cached = settings
        return settings
    }

    func save(_ settings: AppSettings) throws {
        try validate(settings)

        let url = try settingsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
        self.cached = settings
    }

    private func settingsURL() throws -> URL {
        if let settingsURLOverride {
            return settingsURLOverride
        }

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private func validate(_ settings: AppSettings) throws {
        if settings.codex.track1Source != .methodB {
            throw SettingsError.invalidCodexTrack1Source
        }

        if settings.claude.allowMethodC == false, settings.claude.track1Source == .methodC {
            throw SettingsError.invalidClaudeTrack1Source
        }
    }
}

enum SettingsError: Error, Equatable {
    case invalidCodexTrack1Source
    case invalidClaudeTrack1Source
}
