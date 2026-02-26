import Foundation

actor Track2Store {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let pointsURLOverride: URL?
    private var cache: Cache?

    private struct Cache {
        var points: [Track2TimelinePoint]
        var modificationDate: Date?
    }

    init(pointsURLOverride: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.pointsURLOverride = pointsURLOverride
    }

    func loadAll() throws -> [Track2TimelinePoint] {
        let url = try pointsURL()
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let currentModificationDate = fileExists ? fileModificationDate(at: url) : nil

        if let cache,
           cache.modificationDate == currentModificationDate {
            return cache.points
        }

        guard fileExists else {
            let empty: [Track2TimelinePoint] = []
            self.cache = Cache(points: empty, modificationDate: nil)
            return empty
        }

        let data = try Data(contentsOf: url)
        let points = try decoder.decode([Track2TimelinePoint].self, from: data)
        self.cache = Cache(points: points, modificationDate: currentModificationDate)
        return points
    }

    func replaceAll(_ points: [Track2TimelinePoint]) throws {
        let url = try pointsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(points)
        try data.write(to: url, options: [.atomic])
        self.cache = Cache(points: points, modificationDate: fileModificationDate(at: url))
    }

    func append(_ point: Track2TimelinePoint) throws {
        var all = try loadAll()
        all.append(point)
        try replaceAll(all)
    }

    private func pointsURL() throws -> URL {
        if let pointsURLOverride {
            return pointsURLOverride
        }

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("track2.json")
    }

    private func fileModificationDate(at url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
