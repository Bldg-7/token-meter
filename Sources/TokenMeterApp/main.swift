import AppKit
import TokenMeterLocalization

final class StatusBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.menu = NSMenu()

        if let button = statusItem.button {
            button.title = "TM"
        }

        menu.addItem(NSMenuItem(title: L10n.Menu.openSettings, action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.Menu.quit, action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
