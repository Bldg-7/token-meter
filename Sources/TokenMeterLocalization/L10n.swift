import Foundation

public enum L10n {
    public enum Menu {
        public static var openSettings: String { tr("menu.open_settings") }
        public static var quit: String { tr("menu.quit") }
    }

    private static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, value: key, comment: "")
    }
}
