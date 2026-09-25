import Foundation

struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func parse() throws -> JSONValue {
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { index = 3 }
        let value = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw Self.invalid() }
        return value
    }

    static func invalid() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid or excessively nested JSON."))
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth <= 512 else { throw Self.invalid() }
        whitespace()
        guard index < bytes.count else { throw Self.invalid() }
        switch bytes[index] {
        case 0x7b: return try object(depth: depth)
        case 0x5b: return try array(depth: depth)
        case 0x22: return try .string(string())
        case 0x74:
            try keyword("true")
            return .bool(true)
        case 0x66:
            try keyword("false")
            return .bool(false)
        case 0x6e:
            try keyword("null")
            return .null
        default: return try number()
        }
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        index += 1
        whitespace()
        var values: [String: JSONValue] = [:]
        if consume(0x7d) { return .object(values) }
        while true {
            let key = try string()
            whitespace()
            guard consume(0x3a), values[key] == nil else { throw Self.invalid() }
            values[key] = try value(depth: depth + 1)
            whitespace()
            if consume(0x7d) { return .object(values) }
            guard consume(0x2c) else { throw Self.invalid() }
            whitespace()
        }
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        index += 1
        whitespace()
        var values: [JSONValue] = []
        if consume(0x5d) { return .array(values) }
        while true {
            values.append(try value(depth: depth + 1))
            whitespace()
            if consume(0x5d) { return .array(values) }
            guard consume(0x2c) else { throw Self.invalid() }
        }
    }

    private mutating func string() throws -> String {
        let start = index
        guard consume(0x22) else { throw Self.invalid() }
        while index < bytes.count {
            if bytes[index] == 0x22 {
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            if bytes[index] == 0x5c { index += 1 }
            index += 1
        }
        throw Self.invalid()
    }

    private mutating func number() throws -> JSONValue {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[index]) { index += 1 }
        guard let literal = String(bytes: bytes[start..<index], encoding: .utf8), JSONNumber.isValid(literal) else {
            throw Self.invalid()
        }
        return .number(JSONNumber(literal: literal))
    }

    private mutating func keyword(_ text: String) throws {
        guard bytes[index...].starts(with: text.utf8) else { throw Self.invalid() }
        index += text.utf8.count
    }

    private mutating func whitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
