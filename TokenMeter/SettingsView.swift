import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appLocale: AppLocaleController

    @State private var settings: AppSettings = AppSettings()
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var didLoad: Bool = false

    @State private var diagnosticsLines: [String] = []
    @State private var diagnosticsError: String?
    @State private var diagnosticsIsRefreshing: Bool = false

    @State private var codexOverrideWarning: String?
    @State private var codexOverrideInfo: String?
    @State private var claudeOverrideWarning: String?
    @State private var claudeOverrideInfo: String?

    @State private var codexProbeTask: Task<Void, Never>?
    @State private var claudeProbeTask: Task<Void, Never>?

    var body: some View {
        Form {
            Text("settings.title")

            Section {
                Picker("settings.locale.label", selection: localeSelection) {
                    Text("settings.locale.system").tag("system")
                    Text("settings.locale.english").tag("en")
                    Text("settings.locale.korean").tag("ko")
                }
                .pickerStyle(.segmented)
                .disabled(!didLoad)
            }

            Section {
                Picker("settings.track2_range.label", selection: $settings.widgetTrack2TimeScale) {
                    ForEach(Track2WidgetTimeScale.allCases) { scale in
                        Text(scale.rawValue).tag(scale)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!didLoad)

                Text("settings.track2_range.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("settings.codex.enable", isOn: $settings.codex.enabled)
                    .disabled(!didLoad)

                TextField(
                    "settings.codex.cli_path_override",
                    text: codexCLIPathOverrideText
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!didLoad)

                Text("settings.codex.cli_path_help")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let codexOverrideWarning {
                    Text(codexOverrideWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let codexOverrideInfo {
                    Text(codexOverrideInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("settings.codex.header")
            }

            Section {
                Toggle("settings.claude.enable", isOn: $settings.claude.enabled)
                    .disabled(!didLoad)

                Toggle("settings.claude.allow_method_c", isOn: $settings.claude.allowMethodC)
                    .disabled(!didLoad)

                Text("settings.claude.allow_method_c.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(
                    "settings.claude.cli_path_override",
                    text: claudeCLIPathOverrideText
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!didLoad)

                if let claudeOverrideWarning {
                    Text(claudeOverrideWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let claudeOverrideInfo {
                    Text(claudeOverrideInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("settings.claude.header")
            }

            Section {
                HStack(spacing: 8) {
                    Text("settings.diagnostics.recent")
                    Spacer()

                    if diagnosticsIsRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button("settings.diagnostics.refresh") {
                        Task {
                            await refreshDiagnostics()
                        }
                    }
                    .disabled(!didLoad || diagnosticsIsRefreshing)
                }

                if let diagnosticsError {
                    Text(diagnosticsError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if diagnosticsLines.isEmpty {
                    Text("settings.diagnostics.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(diagnosticsLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("settings.diagnostics.header")
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !didLoad {
                ProgressView()
            }
        }
        .padding(16)
        .frame(width: 420)
        .task {
            await loadSettings()
        }
        .onChange(of: settings.claude.allowMethodC) { _ in
            guard didLoad else { return }
            Task {
                await saveSettings()
            }
        }
        .onChange(of: settings.codex.enabled) { _ in
            guard didLoad else { return }
            Task { await saveSettings() }
        }
        .onChange(of: settings.claude.enabled) { _ in
            guard didLoad else { return }
            Task { await saveSettings() }
        }
        .onChange(of: settings.locale) { _ in
            guard didLoad else { return }
            appLocale.setSetting(settings.locale)
            Task { await saveSettings() }
        }
        .onChange(of: settings.widgetTrack2TimeScale) { _ in
            guard didLoad else { return }
            Task { await saveSettings() }
        }
        .onChange(of: settings.codex.cliPathOverride) { _ in
            guard didLoad else { return }
            Task { await saveSettings() }
            scheduleCodexProbe()
        }
        .onChange(of: settings.claude.cliPathOverride) { _ in
            guard didLoad else { return }
            Task { await saveSettings() }
            scheduleClaudeProbe()
        }
    }

    private var codexCLIPathOverrideText: Binding<String> {
        Binding(
            get: { settings.codex.cliPathOverride ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.codex.cliPathOverride = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var localeSelection: Binding<String> {
        Binding(
            get: {
                switch settings.locale {
                case .system:
                    return "system"
                case .fixed(let value):
                    if value == "en" || value == "ko" { return value }
                    return "system"
                }
            },
            set: { newValue in
                if newValue == "system" {
                    settings.locale = .system
                } else {
                    settings.locale = .fixed(newValue)
                }
            }
        )
    }

    private var claudeCLIPathOverrideText: Binding<String> {
        Binding(
            get: { settings.claude.cliPathOverride ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.claude.cliPathOverride = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    @MainActor
    private func scheduleCodexProbe() {
        codexProbeTask?.cancel()
        let overridePath = settings.codex.cliPathOverride

        if overridePath == nil {
            codexOverrideWarning = nil
            codexOverrideInfo = nil
            return
        }

        codexProbeTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard Task.isCancelled == false else { return }

            let res = await CLIToolDiscovery.probeHealthAsync(toolName: "codex", overridePath: overridePath)
            let (warning, info) = Self.overrideFeedback(toolName: "codex", result: res)
            await MainActor.run {
                codexOverrideWarning = warning
                codexOverrideInfo = info
            }

            await refreshDiagnostics()
        }
    }

    @MainActor
    private func scheduleClaudeProbe() {
        claudeProbeTask?.cancel()
        let overridePath = settings.claude.cliPathOverride

        if overridePath == nil {
            claudeOverrideWarning = nil
            claudeOverrideInfo = nil
            return
        }

        claudeProbeTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard Task.isCancelled == false else { return }

            let res = await CLIToolDiscovery.probeHealthAsync(toolName: "claude", overridePath: overridePath)
            let (warning, info) = Self.overrideFeedback(toolName: "claude", result: res)
            await MainActor.run {
                claudeOverrideWarning = warning
                claudeOverrideInfo = info
            }

            await refreshDiagnostics()
        }
    }

    private static func overrideFeedback(
        toolName: String,
        result: CLIToolHealthProbeResult
    ) -> (warning: String?, info: String?) {
        switch result.discovery.state {
        case .missing:
            return ("\(toolName) not found.", nil)
        case .invalid:
            return (invalidOverrideMessage(toolName: toolName, reason: result.discovery.reasonCode), nil)
        case .found:
            if result.version.state == .found {
                let path = result.discovery.executablePath ?? "(unknown path)"
                if let v = result.version.version {
                    return (nil, "OK: \(path) (version \(v))")
                }
                return (nil, "OK: \(path)")
            }
            return (
                invalidOverrideMessage(toolName: toolName, reason: result.version.reasonCode),
                nil
            )
        }
    }

    private static func invalidOverrideMessage(toolName: String, reason: CLIToolProbeReasonCode?) -> String {
        switch reason {
        case .overrideNotFound:
            return "Path not found. Point this to the \(toolName) executable."
        case .overrideIsDirectory:
            return "Path is a directory. Point this to the \(toolName) executable file."
        case .overrideNotExecutable:
            return "File is not executable. Choose the \(toolName) executable or fix permissions."
        case .versionLaunchFailed:
            return "Found executable, but failed to run `--version`. Check permissions/quarantine."
        case .versionTimedOut:
            return "Found executable, but `--version` timed out."
        case .versionOutputEmpty:
            return "Found executable, but `--version` returned no output."
        case .versionParseFailed:
            return "Found executable, but could not parse a version from `--version` output."
        case .notFound:
            return "Executable not found."
        case nil:
            return "Invalid override."
        }
    }

    @MainActor
    private func refreshDiagnostics() async {
        diagnosticsIsRefreshing = true
        defer {
            diagnosticsIsRefreshing = false
        }

        let export = DiagnosticsStore.shared.exportAllProvidersNDJSON()
        let ndjson = String(data: export.data, encoding: .utf8) ?? ""
        let lines = ndjson
            .split(separator: "\n")
            .suffix(6)
            .map { String($0) }

        diagnosticsLines = lines
        diagnosticsError = nil
    }

    @MainActor
    private func loadSettings() async {
        do {
            settings = try await SettingsStore.shared.load()
            loadError = nil
            didLoad = true

            appLocale.setSetting(settings.locale)

            scheduleCodexProbe()
            scheduleClaudeProbe()

            await refreshDiagnostics()
        } catch {
            loadError = "Failed to load settings: \(String(describing: error))"
        }
    }

    @MainActor
    private func saveSettings() async {
        do {
            try await SettingsStore.shared.save(settings)
            try await WidgetSnapshotRefresher().refresh(settings: settings)
            NotificationCenter.default.post(name: Notification.Name("TokenMeterStoreDidUpdate"), object: nil)
            saveError = nil
        } catch {
            saveError = "Failed to save settings: \(String(describing: error))"
        }
    }
}
