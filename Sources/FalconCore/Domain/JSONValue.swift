import Foundation

public enum JSONValue: Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(JSONNumber)
    case bool(Bool)
    case null

    public static func number(_ value: Double) -> JSONValue { .number(JSONNumber(value)) }

    public subscript(_ key: String) -> JSONValue? { objectValue?[key] }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var numberValue: Double? { if case .number(let value) = self { Double(value.literal) } else { nil } }
    public var integerValue: Int? { if case .number(let value) = self { value.integerValue } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }

    public static func decode(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(data)
        return try parser.parse()
    }

    public func data(pretty: Bool = false, canonicalNumbers: Bool = false) throws -> Data {
        var output = Data()
        try write(to: &output, depth: 0, pretty: pretty, canonicalNumbers: canonicalNumbers)
        return output
    }

    public var displayText: String {
        if case .string(let text) = self { return text }
        return (try? String(data: data(pretty: true), encoding: .utf8)) ?? ""
    }

    private func write(to output: inout Data, depth: Int, pretty: Bool, canonicalNumbers: Bool) throws {
        guard depth <= 512 else { throw JSONParser.invalid() }
        switch self {
        case .null: output.append(contentsOf: "null".utf8)
        case .bool(let value): output.append(contentsOf: (value ? "true" : "false").utf8)
        case .string(let value): output.append(try Self.quoted(value))
        case .number(let value):
            guard JSONNumber.isValid(value.literal) else { throw JSONParser.invalid() }
            output.append(contentsOf: (canonicalNumbers ? value.canonicalLiteral : value.literal).utf8)
        case .array(let values):
            try Self.writeArray(values, to: &output, depth: depth, pretty: pretty, canonicalNumbers: canonicalNumbers)
        case .object(let values):
            try Self.writeObject(values, to: &output, depth: depth, pretty: pretty, canonicalNumbers: canonicalNumbers)
        }
    }

    private static func writeArray(
        _ values: [JSONValue], to output: inout Data, depth: Int, pretty: Bool, canonicalNumbers: Bool
    ) throws {
        output.append(0x5b)
        for (index, value) in values.enumerated() {
            if index > 0 { output.append(0x2c) }
            Self.line(to: &output, depth: depth + 1, pretty: pretty)
            try value.write(to: &output, depth: depth + 1, pretty: pretty, canonicalNumbers: canonicalNumbers)
        }
        if !values.isEmpty { Self.line(to: &output, depth: depth, pretty: pretty) }
        output.append(0x5d)
    }

    private static func writeObject(
        _ values: [String: JSONValue], to output: inout Data, depth: Int, pretty: Bool, canonicalNumbers: Bool
    ) throws {
        output.append(0x7b)
        for (index, key) in values.keys.sorted().enumerated() {
            if index > 0 { output.append(0x2c) }
            Self.line(to: &output, depth: depth + 1, pretty: pretty)
            output.append(try Self.quoted(key))
            output.append(contentsOf: (pretty ? ": " : ":").utf8)
            try values[key]!.write(to: &output, depth: depth + 1, pretty: pretty, canonicalNumbers: canonicalNumbers)
        }
        if !values.isEmpty { Self.line(to: &output, depth: depth, pretty: pretty) }
        output.append(0x7d)
    }

    private static func quoted(_ value: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func line(to output: inout Data, depth: Int, pretty: Bool) {
        guard pretty else { return }
        output.append(0x0a)
        output.append(contentsOf: repeatElement(UInt8(0x20), count: depth * 2))
    }
}
