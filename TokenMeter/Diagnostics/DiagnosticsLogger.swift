import Foundation

struct DiagnosticsLogger {
    private let provider: ProviderId
    private let store: DiagnosticsStore

    init(provider: ProviderId, store: DiagnosticsStore = .shared) {
        self.provider = provider
        self.store = store
    }

    func debug(_ message: String, fields: [String: DiagnosticsValue] = [:], file: String = #fileID, function: String = #function, line: UInt = #line) {
        store.log(provider: provider, level: .debug, message: message, fields: fields, file: file, function: function, line: line)
    }

    func info(_ message: String, fields: [String: DiagnosticsValue] = [:], file: String = #fileID, function: String = #function, line: UInt = #line) {
        store.log(provider: provider, level: .info, message: message, fields: fields, file: file, function: function, line: line)
    }

    func warning(_ message: String, fields: [String: DiagnosticsValue] = [:], file: String = #fileID, function: String = #function, line: UInt = #line) {
        store.log(provider: provider, level: .warning, message: message, fields: fields, file: file, function: function, line: line)
    }

    func error(_ message: String, fields: [String: DiagnosticsValue] = [:], file: String = #fileID, function: String = #function, line: UInt = #line) {
        store.log(provider: provider, level: .error, message: message, fields: fields, file: file, function: function, line: line)
    }
}
