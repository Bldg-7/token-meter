import Foundation
import Sparkle
import SwiftUI
import WidgetKit

@main
struct TokenMeterApp: App {
    @StateObject private var runtime = AppRuntime()
    @StateObject private var appLocale = AppLocaleController()
    @StateObject private var sparkleUpdater = SparkleUpdaterService()

    var body: some Scene {
        MenuBarExtra("app.title", systemImage: "gauge") {
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

        if updater.hasUpdateAvailable {
            Button("menu.check_for_updates") {
                updater.checkForUpdates()
            }

            Divider()
        }

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
                try await WidgetSnapshotRefresher().refresh(settings: settings)
                NotificationCenter.default.post(name: Notification.Name("TokenMeterStoreDidUpdate"), object: nil)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
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
                assertionFailure("Settings load failed: \(String(describing: error))")
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
