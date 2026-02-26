import Foundation
import SwiftUI
import WidgetKit

@main
struct TokenMeterApp: App {
    @StateObject private var runtime = AppRuntime()
    @StateObject private var appLocale = AppLocaleController()

    var body: some Scene {
        MenuBarExtra("app.title", systemImage: "gauge") {
            MenuBarMenuView()
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
