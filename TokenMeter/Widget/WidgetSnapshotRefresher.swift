import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

actor WidgetSnapshotRefresher {
    private let track1Store: Track1Store
    private let track2Store: Track2Store
    private let snapshotStore: WidgetSnapshotStore

    init(
        track1Store: Track1Store = Track1Store(),
        track2Store: Track2Store = Track2Store(),
        snapshotStore: WidgetSnapshotStore = WidgetSnapshotStore()
    ) {
        self.track1Store = track1Store
        self.track2Store = track2Store
        self.snapshotStore = snapshotStore
    }

    func refresh(settings: AppSettings, now: Date = Date()) async throws {
        let snapshots = try await track1Store.loadAll()
        let points = try await track2Store.loadAll()
        let widgetSnapshot = WidgetSnapshotBuilder.make(
            settings: settings,
            track1Snapshots: snapshots,
            track2Points: points,
            now: now
        )
        try snapshotStore.write(widgetSnapshot)

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedConfig.codexWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedConfig.claudeWidgetKind)
        #endif
    }
}
