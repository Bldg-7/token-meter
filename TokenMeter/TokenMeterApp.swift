import CoreServices
import Foundation
import Sparkle
import SwiftUI
import WidgetKit

@main
struct TokenMeterApp: App {
    @StateObject private var runtime = AppRuntime()
    @StateObject private var appLocale = AppLocaleController()
    @StateObject private var sparkleUpdater = SparkleUpdaterService()

    init() {
        LaunchServicesRegistration.refreshAfterLaunch()
    }

    var body: some Scene {
        MenuBarExtra("app.title", image: "StatusBarIcon") {
            MenuBarMenuView(updater: sparkleUpdater)
                .environment(\.locale, appLocale.swiftUILocale)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            SettingsView()
                .environmentObject(appLocale)
                .environment(\.locale, appLocale.swiftUILocale)
        }
    }
}

private struct MenuBarMenuView: View {
    let updater: SparkleUpdaterService
    @State private var selectedScale: Track2WidgetTimeScale = .hours24

    var body: some View {
        Menu("menu.time_range_option") {
            ForEach(Track2WidgetTimeScale.allCases) { scale in
                Button {
                    apply(scale)
                } label: {
                    HStack {
                        Text(scale.rawValue)
                        if selectedScale == scale {
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Divider()

        Button(updater.hasUpdateAvailable ? "menu.install_update" : "menu.check_for_updates") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

        if updater.hasUpdateAvailable {
            Text("menu.update_available")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        Divider()

        (Text("menu.version") + Text(" \(updater.currentVersion)"))
            .foregroundStyle(.secondary)

        Divider()

        Button("menu.quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .task {
            await loadSelectedScale()
        }
    }

    private func apply(_ scale: Track2WidgetTimeScale) {
        selectedScale = scale

        Task {
            do {
                var settings = try await SettingsStore.shared.load()
                settings.widgetTrack2TimeScale = scale
                try await SettingsStore.shared.save(settings)
                // The refresher reloads both widget kinds itself when the
                // snapshot changed; a second blanket reload only burns budget.
                try await WidgetSnapshotRefresher().refresh(settings: settings)
                NotificationCenter.default.post(name: Notification.Name("TokenMeterStoreDidUpdate"), object: nil)
            } catch {
                DiagnosticsLogger(provider: .codex).warning("widget_scale_apply_failed", fields: ["error": .string(String(describing: error))])
                DiagnosticsLogger(provider: .claude).warning("widget_scale_apply_failed", fields: ["error": .string(String(describing: error))])
            }
        }
    }

    private func loadSelectedScale() async {
        do {
            let settings = try await SettingsStore.shared.load()
            await MainActor.run {
                selectedScale = settings.widgetTrack2TimeScale
            }
        } catch {
        }
    }
}

@MainActor
final class SparkleUpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var hasUpdateAvailable = false
    @Published private(set) var canCheckForUpdates = false
    let currentVersion: String

    private lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()
    private var canCheckObservation: NSKeyValueObservation?
    private var hasProbedForUpdate = false

    override init() {
        currentVersion = Self.makeCurrentVersionString()
        super.init()
        _ = controller
        bindCanCheckState()
        probeForUpdateIfPossible()
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        hasUpdateAvailable = true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        hasUpdateAvailable = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        hasUpdateAvailable = false
    }

    private func bindCanCheckState() {
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canCheckForUpdates = self.controller.updater.canCheckForUpdates
                self.probeForUpdateIfPossible()
            }
        }
    }

    private func probeForUpdateIfPossible() {
        guard !hasProbedForUpdate else { return }
        guard controller.updater.canCheckForUpdates else { return }
        hasProbedForUpdate = true
        controller.updater.checkForUpdateInformation()
    }

    private static func makeCurrentVersionString(bundle: Bundle = .main) -> String {
        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !shortVersion.isEmpty {
            return shortVersion
        }

        let buildVersion = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return buildVersion.isEmpty ? "n/a" : buildVersion
    }
}

@MainActor
final class AppLocaleController: ObservableObject {
    @Published private(set) var setting: AppLocaleSetting

    init(initialSetting: AppLocaleSetting = .system, loadFromStore: Bool = true) {
        self.setting = initialSetting

        guard loadFromStore else { return }
        Task { [weak self] in
            do {
                let settings = try await SettingsStore.shared.load()
                await MainActor.run {
                    self?.setSetting(settings.locale)
                }
            } catch {
                // Unreadable settings fall back to the system locale; the
                // runtime logs the failure and runs on defaults.
            }
        }
    }

    func setSetting(_ newValue: AppLocaleSetting) {
        if setting != newValue {
            setting = newValue
        }
    }

    var swiftUILocale: Locale {
        switch setting {
        case .system:
            return .autoupdatingCurrent
        case .fixed(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .autoupdatingCurrent
            }
            return Locale(identifier: trimmed)
        }
    }
}

/// Re-registers the app bundle and its widget extension with LaunchServices
/// on every launch, then reloads the widgets.
///
/// After an in-place update (Sparkle swaps the bundle under the same path)
/// the LaunchServices database can keep the extension's previous version.
/// chronod then rejects every timeline the extension produces ("Bundle
/// version did not match; LaunchServices DB may need to be rebuilt") and the
/// widget stays frozen on its last archive until the database is refreshed,
/// which is what `lsregister -f -R` does by hand and this does on launch.
enum LaunchServicesRegistration {
    static func refreshAfterLaunch() {
        DispatchQueue.global(qos: .utility).async {
            var bundleURLs = [Bundle.main.bundleURL]
            if let plugInsURL = Bundle.main.builtInPlugInsURL,
               let plugIns = try? FileManager.default.contentsOfDirectory(
                   at: plugInsURL,
                   includingPropertiesForKeys: nil
               )
            {
                bundleURLs += plugIns.filter { $0.pathExtension == "appex" }
            }

            for url in bundleURLs {
                let status = LSRegisterURL(url as CFURL, true)
                if status != noErr {
                    DiagnosticsLogger(provider: .codex).warning(
                        "launch_services_register_failed",
                        fields: ["bundle": .string(url.lastPathComponent), "status": .int(Int(status))]
                    )
                }
            }

            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
