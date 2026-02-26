import Foundation
import Dispatch

enum DiagnosticsLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

struct DiagnosticsEvent: Codable, Equatable, Sendable {
    var provider: ProviderId
    var level: DiagnosticsLogLevel
    var timestamp: Date
    var sequence: UInt64
    var message: String
    var fields: [String: DiagnosticsValue]
    var file: String
    var function: String
    var line: UInt
}

struct DiagnosticsExport: Sendable {
    var mimeType: String
    var fileName: String
    var data: Data
}

final class DiagnosticsStore: @unchecked Sendable {
    static let shared = DiagnosticsStore()

    private let queue = DispatchQueue(label: "TokenMeter.DiagnosticsStore")
    private let redactor: DiagnosticsRedactor
    private let maxEventsPerProvider: Int
    private let now: () -> Date

    private var nextSequence: UInt64 = 1
    private var eventsByProvider: [ProviderId: [DiagnosticsEvent]] = [:]

    init(
        maxEventsPerProvider: Int = 1000,
        redactor: DiagnosticsRedactor = DiagnosticsRedactor(),
        now: @escaping () -> Date = Date.init
    ) {
        self.maxEventsPerProvider = max(1, maxEventsPerProvider)
        self.redactor = redactor
        self.now = now
    }

    func log(
        provider: ProviderId,
        level: DiagnosticsLogLevel,
        message: String,
        fields: [String: DiagnosticsValue] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        let redactedMessage = redactor.redactMessage(message)
        let redactedFields = redactor.redactFields(fields)

        queue.sync {
            let event = DiagnosticsEvent(
                provider: provider,
                level: level,
                timestamp: now(),
                sequence: nextSequence,
                message: redactedMessage,
                fields: redactedFields,
                file: file,
                function: function,
                line: line
            )
            nextSequence &+= 1

            var arr = eventsByProvider[provider] ?? []
            arr.append(event)
            if arr.count > maxEventsPerProvider {
                arr.removeFirst(arr.count - maxEventsPerProvider)
            }
            eventsByProvider[provider] = arr
        }
    }

    func clear(provider: ProviderId) {
        queue.sync {
            eventsByProvider[provider] = []
        }
    }

    func clearAll() {
        queue.sync {
            eventsByProvider.removeAll(keepingCapacity: true)
        }
    }

    func exportProviderNDJSON(provider: ProviderId) -> DiagnosticsExport {
        let events: [DiagnosticsEvent] = queue.sync {
            eventsByProvider[provider] ?? []
        }
        return exportNDJSON(fileName: "diagnostics-\(provider.rawValue).ndjson", events: events)
    }

    func exportAllProvidersNDJSON() -> DiagnosticsExport {
        let events: [DiagnosticsEvent] = queue.sync {
            eventsByProvider.keys.sorted(by: { $0.rawValue < $1.rawValue }).flatMap { pid in
                eventsByProvider[pid] ?? []
            }
        }
        return exportNDJSON(fileName: "diagnostics.ndjson", events: events)
    }

    private func exportNDJSON(fileName: String, events: [DiagnosticsEvent]) -> DiagnosticsExport {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var data = Data()
        for event in events {
            if let line = try? encoder.encode(event) {
                data.append(line)
                data.append(0x0A)
            }
        }

        return DiagnosticsExport(
            mimeType: "application/x-ndjson",
            fileName: fileName,
            data: data
        )
    }
}
