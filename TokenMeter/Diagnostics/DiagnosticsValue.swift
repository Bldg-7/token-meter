import Foundation

enum DiagnosticsValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([DiagnosticsValue])
    case object([String: DiagnosticsValue])
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var out: [String: DiagnosticsValue] = [:]
            for key in container.allKeys {
                out[key.stringValue] = try container.decode(DiagnosticsValue.self, forKey: key)
            }
            self = .object(out)
            return
        }

        var arrayContainer: UnkeyedDecodingContainer
        if let c = try? decoder.unkeyedContainer() {
            arrayContainer = c
            var values: [DiagnosticsValue] = []
            while arrayContainer.isAtEnd == false {
                values.append(try arrayContainer.decode(DiagnosticsValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let d = try? container.decode(Double.self) {
            self = .double(d)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .int(let i):
            var c = encoder.singleValueContainer()
            try c.encode(i)
        case .double(let d):
            var c = encoder.singleValueContainer()
            try c.encode(d)
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .array(let arr):
            var c = encoder.unkeyedContainer()
            for v in arr {
                try c.encode(v)
            }
        case .object(let obj):
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            for (k, v) in obj {
                try c.encode(v, forKey: AnyCodingKey(k))
            }
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        }
    }
}

private struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
