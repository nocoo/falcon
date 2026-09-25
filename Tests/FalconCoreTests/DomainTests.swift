import Foundation
import Testing

@testable import FalconCore

@Test func jsonPreservesStructuredDefinitions() throws {
    let data = Data(#"{"state":["text",1,true,null],"define":{"nested":false},"number":0.5}"#.utf8)
    let value = try JSONValue.decode(data)
    #expect(try JSONValue.decode(value.data()) == value)
    #expect(value["state"]?.arrayValue?.count == 4)
    #expect(value["define"]?["nested"]?.boolValue == false)
    #expect(value["number"]?.numberValue == 0.5)
    #expect(JSONValue.string("plain").displayText == "plain")
    #expect(throws: (any Error).self) { try JSONValue.decode(Data("{".utf8)) }
}

@Test func jsonPreservesNumericEvidenceWithoutRounding() throws {
    let literals = [
        "9007199254740993", "9223372036854775807", "18446744073709551615",
        "12345678901234567890123456789012345678901234567890", "0.12345678901234567890123456789012345678901234567890",
        "-0", "1e-999", "1e999999999999999999999999999999",
    ]
    let raw = Data(("[" + literals.joined(separator: ",") + "]").utf8)
    let value = try JSONValue.decode(raw)
    #expect(try value.data() == raw)
    for (value, literal) in zip(try #require(value.arrayValue), literals) { #expect(value.displayText == literal) }
    let integer = try JSONValue.decode(Data("9007199254740993".utf8))
    let equivalent = try JSONValue.decode(Data("90071992547409930e-1".utf8))
    let adjacent = try JSONValue.decode(Data("9007199254740992".utf8))
    #expect(integer == equivalent)
    #expect(integer != adjacent)
    #expect(try integer.data(canonicalNumbers: true) == equivalent.data(canonicalNumbers: true))
    #expect(try integer.data(canonicalNumbers: true) != adjacent.data(canonicalNumbers: true))
    #expect(integer.integerValue == 9_007_199_254_740_993)
    #expect(try JSONValue.decode(Data("-9223372036854775808".utf8)).integerValue == Int.min)
    #expect(try JSONValue.decode(Data("9223372036854775808".utf8)).integerValue == nil)
    #expect(try JSONValue.decode(Data("9007199254740993.1".utf8)).integerValue == nil)
}

@Test func jsonRejectsAmbiguousOrMalformedEvidence() throws {
    let malformed = [
        "", "[1,]", #"{"a":1,}"#, #"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#, "[+1]", "[01]", "[1.]", "[.1]", "[1e]",
        "[1e+]", "[NaN]", "[Infinity]", "[truefalse]", "{}[]", #"{"a" 1}"#, #""\x00""#, #""\uD800""#, "[1\u{2028}]",
        "[1\u{0085}]", String(repeating: "[", count: 514) + "0" + String(repeating: "]", count: 514),
    ]
    for text in malformed { #expect(throws: (any Error).self) { try JSONValue.decode(Data(text.utf8)) } }
    #expect(throws: (any Error).self) { try JSONValue.decode(Data([0x22, 0xff, 0x22])) }
    #expect(throws: (any Error).self) { try JSONValue.number(.infinity).data() }
    let escaped = Data(#"{"a":"quote: \" \\ \n \uD83D\uDE00","b":[{},[],false,null,-1.25e+2]}"#.utf8)
    let value = try JSONValue.decode(escaped)
    #expect(value["a"]?.stringValue == "quote: \" \\ \n 😀")
    #expect(try JSONValue.decode(value.data(pretty: true)) == value)
    #expect(try JSONValue.decode(Data([0xef, 0xbb, 0xbf]) + escaped) == value)
}

@Test func jsonMatchesFoundationForStructuredBoundaryValues() throws {
    let strings = ["", "\"quoted\"", "\\path/", "\n\r\t\u{0000}", "中文 😀 é", "{} [] 1e9"]
    for index in 0..<64 {
        let text = strings[index % strings.count]
        let expected: [String: Any] = [
            "id": Int.max - index, "text": text, "active": index.isMultiple(of: 2),
            "nested": [["minimum": Int.min + index], [true, NSNull(), [String: String]()]],
        ]
        let original = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        let value = try JSONValue.decode(original)
        #expect(value["id"]?.integerValue == Int.max - index)
        #expect(value["text"]?.stringValue == text)
        let decoded = try #require(
            JSONSerialization.jsonObject(with: value.data(pretty: index.isMultiple(of: 2))) as? NSDictionary)
        #expect(decoded.isEqual(NSDictionary(dictionary: expected)))
    }
}

@Test func timingNeverInventsUnknownIntervals() {
    #expect(RequestTiming().upstreamMS == nil)
    let timing = RequestTiming(bodyReceivedMS: 3, upstreamStartedMS: 10, responseReceivedMS: 210, terminalMS: 215)
    #expect(timing.upstreamMS == 200)
    #expect(timing.lastKnownMS == 215)
    #expect(timing.deliveryFinishedMS == nil)
    #expect(!RequestStatus.inFlight.isTerminal)
    #expect(RequestStatus.interrupted.isFailure)
}

@Test func optionalStarAnnotationDefaultsToUnstarred() throws {
    let summary = RequestSummary(
        sourceID: UUID(), keyID: UUID(), sourceName: "Synthetic", profileID: UUID(), profileName: "Synthetic")
    let encoded = try JSONEncoder().encode(summary)
    let encodedText = try #require(String(bytes: encoded, encoding: .utf8))
    #expect(!encodedText.contains("starredAt"))
    let restored = try JSONDecoder().decode(RequestSummary.self, from: encoded)
    #expect(!restored.isStarred && restored.starredAt == nil)
    #expect(restored.isRetained(at: summary.expiresAt.addingTimeInterval(-1)))
    #expect(!restored.isRetained(at: summary.expiresAt))
}
