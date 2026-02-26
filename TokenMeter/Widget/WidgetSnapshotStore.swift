import Foundation

struct WidgetSnapshotStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let containerURLOverride: URL?

    init(containerURLOverride: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.containerURLOverride = containerURLOverride
    }

    func write(_ snapshot: WidgetSnapshot) throws {
        let url = try snapshotURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }

    func read() throws -> WidgetSnapshot? {
        let url = try snapshotURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(WidgetSnapshot.self, from: data)
    }

    private func snapshotURL() throws -> URL {
        if let containerURLOverride {
            return containerURLOverride.appendingPathComponent(WidgetSharedConfig.snapshotFileName)
        }

        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSharedConfig.appGroupIdentifier
        ) else {
            throw SnapshotStoreError.unavailableAppGroup(WidgetSharedConfig.appGroupIdentifier)
        }

        return groupURL.appendingPathComponent(WidgetSharedConfig.snapshotFileName)
    }
}

enum SnapshotStoreError: Error, Equatable {
    case unavailableAppGroup(String)
}
