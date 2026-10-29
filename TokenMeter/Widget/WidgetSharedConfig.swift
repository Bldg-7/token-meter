import Foundation

enum WidgetSharedConfig {
    // Developer ID builds carry no provisioning profile, so macOS only lets
    // them write to a group container whose identifier starts with the
    // signing team ID; a "group."-style identifier is rejected outright
    // (macOS 27.2+). Must match both targets' entitlements.
    static let appGroupIdentifier = "SYZS4D43Z6.com.tokenmeter.app"
    static let snapshotFileName = "widget_snapshot.json"
    static let codexWidgetKind = "TokenMeterCodexWidget"
    static let claudeWidgetKind = "TokenMeterClaudeWidget"
}
