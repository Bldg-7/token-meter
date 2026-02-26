import Foundation

actor Track1Store {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let snapshotsURLOverride: URL?
    private var cache: Cache?

    private struct Cache {
        var snapshots: [Track1Snapshot]
        var modificationDate: Date?
    }

    init(snapshotsURLOverride: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.snapshotsURLOverride = snapshotsURLOverride
    }

    func loadAll() throws -> [Track1Snapshot] {
        let url = try snapshotsURL()
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let currentModificationDate = fileExists ? fileModificationDate(at: url) : nil

        if let cache,
           cache.modificationDate == currentModificationDate {
            return cache.snapshots
        }

        guard fileExists else {
            let empty: [Track1Snapshot] = []
            self.cache = Cache(snapshots: empty, modificationDate: nil)
            return empty
        }

        let data = try Data(contentsOf: url)
        let snapshots = try decoder.decode([Track1Snapshot].self, from: data)
        self.cache = Cache(snapshots: snapshots, modificationDate: currentModificationDate)
        return snapshots
    }

    func replaceAll(_ snapshots: [Track1Snapshot]) throws {
        let url = try snapshotsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshots)
        try data.write(to: url, options: [.atomic])
        self.cache = Cache(snapshots: snapshots, modificationDate: fileModificationDate(at: url))
    }

    func append(_ snapshot: Track1Snapshot) throws {
        var all = try loadAll()
        all.append(snapshot)
        try replaceAll(all)
    }

    private func snapshotsURL() throws -> URL {
        if let snapshotsURLOverride {
            return snapshotsURLOverride
        }

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("track1.json")
    }

    private func fileModificationDate(at url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
