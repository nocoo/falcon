import Foundation
import Testing

@testable import FalconCore

@Test func typeSafeOptionalQuestionFieldsRemainUnchanged() throws {
    let questions: [JSONValue] = [
        .object(["type": .string("noul")]),
        .object(["type": .string("noul"), "instructions": .null, "criteria": .null]),
        .object(["type": .string("noul"), "criteria": .object(["true": .string("Yes")])]),
        .object(["type": .string("noul"), "criteria": .object(["false": .null, "extension": .number(1)])]),
        .object(["type": .string("choice"), "criteria": .object(["": .null])]),
        .object(["type": .string("score"), "instructions": .null, "criteria": .array([.string("only")])]),
        .object(["type": .string("score"), "criteria": .array(Array(repeating: .string("level"), count: 11))]),
    ]
    for question in questions {
        let root: JSONValue = .object([
            "state": .string("synthetic"), "model": .string("jev-latest"), "questions": .object(["": question]),
        ])
        let request = try JevRequest(root)
        #expect(request.value == root)
    }
}

@Test func typeSafeKnownQuestionTypesStillValidateFieldTypes() throws {
    let invalid: [JSONValue] = [
        .object(["type": .string("noul"), "instructions": .bool(true)]),
        .object(["type": .string("noul"), "criteria": .string("wrong")]),
        .object(["type": .string("noul"), "criteria": .object(["true": .number(1)])]),
        .object(["type": .string("choice"), "criteria": .array([.string("wrong")])]),
        .object(["type": .string("choice"), "criteria": .object(["a": .bool(true)])]),
        .object(["type": .string("score"), "criteria": .array([])]),
        .object(["type": .string("score"), "criteria": .array([.null])]),
    ]
    for question in invalid {
        #expect(throws: FalconError.self) {
            try JevRequest(
                .object([
                    "state": .string("synthetic"), "model": .string("jev-latest"),
                    "questions": .object(["q": question]),
                ]))
        }
    }
}

@Test func typeSafeModelsUseBoundProfileAndSafeResponseHeaders() async throws {
    let source = AgentSource(name: "Synthetic", profileID: UUID())
    let snapshot = ExecutionSnapshot(
        identity: SourceIdentity(source: source, keyID: UUID()),
        profile: UpstreamProfile(id: source.profileID, name: "Gateway", baseURL: "https://fixture.invalid/api"),
        endpoint: URL(string: "https://fixture.invalid/api/v1/systemone")!, credential: "synthetic-upstream-key")
    let client = JevClient { request in
        #expect(request.url?.absoluteString == "https://fixture.invalid/api/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-upstream-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        return (
            Data(#"{"detail":"synthetic limit"}"#.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json", "Retry-After": "2", "retry-after-ms": "1500",
                    "x-typesafe-request-id": "synthetic-request", "Set-Cookie": "secret=synthetic",
                    "Authorization": "Bearer synthetic-secret",
                ])!
        )
    }
    let reply = try await client.listModels(snapshot: snapshot)
    #expect(reply.status == 429)
    #expect(
        DecisionService.upstreamHeaders(reply) == [
            "Content-Type": "application/json", "Retry-After": "2", "retry-after-ms": "1500",
            "x-typesafe-request-id": "synthetic-request", "X-Falcon-Error-Origin": "upstream",
        ])
}
