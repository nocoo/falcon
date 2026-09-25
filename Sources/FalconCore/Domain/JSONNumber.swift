import Foundation

public struct JSONNumber: Sendable, Equatable {
    let literal: String

    init(_ value: Double) {
        literal = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? String(value)
    }

    init(literal: String) { self.literal = literal }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.canonicalLiteral == rhs.canonicalLiteral }

    var integerValue: Int? {
        let canonical = canonicalLiteral
        if canonical == "0" { return 0 }
        let parts = canonical.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count == 2, let exponent = Int(parts[1]), exponent >= 0, exponent <= 19,
            parts[0].count + exponent <= 20
        else { return nil }
        return Int(String(parts[0]) + String(repeating: "0", count: exponent))
    }

    var canonicalLiteral: String {
        let parts = literal.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard let significand = parts.first, parts.count <= 2 else { return literal }
        let negative = significand.first == "-"
        let magnitude = negative ? significand.dropFirst() : significand[...]
        let fraction = magnitude.split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(fraction.joined().utf8.drop(while: { $0 == 0x30 }))
        if digits.isEmpty { return "0" }
        guard let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return literal }
        let decimalPlaces = fraction.count == 2 ? fraction[1].count : 0
        let (initialScale, initialOverflow) = exponent.subtractingReportingOverflow(decimalPlaces)
        guard !initialOverflow else { return literal }
        var trailingZeroes = 0
        while digits.last == 0x30 {
            digits.removeLast()
            trailingZeroes += 1
        }
        let (scale, overflow) = initialScale.addingReportingOverflow(trailingZeroes)
        guard !overflow else { return literal }
        return (negative ? "-" : "") + (String(bytes: digits, encoding: .utf8) ?? literal) + "e\(scale)"
    }

    static func isValid(_ literal: String) -> Bool {
        literal.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) == literal
            .startIndex..<literal.endIndex
    }
}
