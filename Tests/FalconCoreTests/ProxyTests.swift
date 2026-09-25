import Foundation
import Testing

@testable import FalconCore

@Test func jevShapesAndUnknownFields() throws {
    let raw = Data(
        #"""
        {"state":{"task":"synthetic"},"model":"jev-latest","extra_body":{"flag":true},
        "questions":{"c":{"type":"choice","instructions":["choose"],
        "criteria":{"a":"A","b":null},"custom":7},
        "n":{"type":"noul","instructions":{"ask":"yes"}},
        "s":{"type":"score","instructions":"rate","criteria":["low",{"label":"high"}]}}}
        """#.utf8)
    let request = try JevRequest(JSONValue.decode(raw))
    #expect(request.questions.count == 3)
    #expect(request.value["extra_body"]?["flag"]?.boolValue == true)
    #expect(request.value["questions"]?["c"]?["custom"]?.numberValue == 7)
    let response = try JevResponse(
        JSONValue.decode(
            Data(
                #"""
                {"model":"jev-1","answers":{"c":{"type":"choice","choice":"a",
                "probabilities":{"a":0.6,"b":0.4},"confidence":0.2},
                "n":{"type":"noul","noul":0.9},"s":{"type":"score","score":0.7,
                "legend":{"0":"low","1":{"label":"high"}},
                "probabilities":{"0":0.3,"1":0.7},"confidence":0.5}},
                "usage":{"input_tokens":10,"output_tokens":3},"future":true}
                """#.utf8)), request: request)
    #expect(response.resolvedModel == "jev-1")
    #expect(response.inputTokens == 10)
    #expect(response.value["future"]?.boolValue == true)
}

@Test func jevRejectsInvalidKnownResults() throws {
    let request = try JevRequest(
        JSONValue.decode(
            Data(
                #"""
                {"state":"x","model":"jev-latest","questions":{
                "c":{"type":"choice","instructions":"choose","criteria":{"a":"A","b":"B"}}}}
                """#.utf8)))
    #expect(throws: FalconError.self) {
        try JevResponse(
            JSONValue.decode(
                Data(
                    #"""
                    {"model":"jev-1","answers":{"c":{"type":"choice","choice":"missing",
                    "probabilities":{"a":0.5,"b":0.5},"confidence":0.8}}}
                    """#.utf8)), request: request)
    }
    #expect(throws: FalconError.self) {
        try JevResponse(
            JSONValue.decode(
                Data(
                    #"""
                    {"model":"jev-1","answers":{"c":{"type":"choice","choice":"a",
                    "probabilities":{"a":0.8,"b":0.8},"confidence":0.8}}}
                    """#.utf8)), request: request)
    }
    #expect(throws: FalconError.self) {
        try JevRequest(
            JSONValue.decode(Data(#"{"state":"x","questions":{"x":{"type":"unknown","instructions":"x"}}}"#.utf8)),
            defaultModel: "jev-latest")
    }
}

@Test func jevUsageTokenCountsRejectUnrepresentableNumbers() throws {
    let request = try JevRequest(
        .object([
            "state": .string("synthetic"), "model": .string("jev-latest"),
            "questions": .object(["n": .object(["type": .string("noul"), "instructions": .string("decide")])]),
        ]))
    let counts: [(Double, Int?)] = [
        (Double(Int.max), nil), (.greatestFiniteMagnitude, nil), (-1, nil), (1.5, nil), (42, 42),
    ]
    for (number, expected) in counts {
        let response = try JevResponse(
            .object([
                "model": .string("jev-latest"),
                "answers": .object(["n": .object(["type": .string("noul"), "noul": .number(0.5)])]),
                "usage": .object(["input_tokens": .number(number), "output_tokens": .number(number)]),
            ]), request: request)
        #expect(response.inputTokens == expected)
        #expect(response.outputTokens == expected)
    }
}

@Test func jevUsageRetainsExactIntegerCounts() throws {
    let request = try JevRequest(
        .object([
            "state": .string("synthetic"), "model": .string("jev-latest"),
            "questions": .object(["n": .object(["type": .string("noul"), "instructions": .string("decide")])]),
        ]))
    let counts: [(String, Int?)] = [
        ("9007199254740993", 9_007_199_254_740_993), ("9223372036854775807", Int.max), ("9223372036854775808", nil),
        ("9007199254740993.1", nil), ("42.00", 42), ("42e0", 42),
    ]
    for (literal, expected) in counts {
        let raw = """
            {"model":"jev-latest","answers":{"n":{"type":"noul","noul":0.5}},
            "usage":{"input_tokens":\(literal),"output_tokens":\(literal)}}
            """
        let response = try JevResponse(JSONValue.decode(Data(raw.utf8)), request: request)
        #expect(response.inputTokens == expected)
        #expect(response.outputTokens == expected)
    }
}

@Test func jevClientForwardsOnlyFixedHeadersOnce() async throws {
    let calls = RequestCounter()
    let endpoint = URL(string: "https://fixture.invalid/v1/systemone")!
    let source = AgentSource(name: "synthetic", profileID: UUID())
    let identity = SourceIdentity(source: source, keyID: UUID())
    let profile = UpstreamProfile(id: source.profileID, name: "synthetic", baseURL: "https://fixture.invalid")
    let snapshot = ExecutionSnapshot(
        identity: identity, profile: profile, endpoint: endpoint, credential: "synthetic-upstream-key")
    let client = JevClient { request in
        await calls.record(request)
        return (
            Data("{}".utf8),
            HTTPURLResponse(
                url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        )
    }
    let result = try await client.send(Data("{}".utf8), snapshot: snapshot)
    #expect(result.status == 200)
    #expect(await calls.count == 1)
    #expect(await calls.authorization == "Bearer synthetic-upstream-key")
    #expect(await calls.headerNames == Set(["Authorization", "Content-Type", "Accept", "User-Agent"]))
}

private actor RequestCounter {
    private(set) var count = 0
    private(set) var authorization: String?
    private(set) var headerNames: Set<String> = []
    func record(_ request: URLRequest) {
        count += 1
        authorization = request.value(forHTTPHeaderField: "Authorization")
        headerNames = Set(request.allHTTPHeaderFields?.keys.map { $0 } ?? [])
    }
}
