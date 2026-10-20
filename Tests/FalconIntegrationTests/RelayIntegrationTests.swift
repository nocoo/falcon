import Foundation
import Testing

@testable import FalconCore

private let relayInput = Data(#"{"model":"jev-latest","state":"synthetic","questions":{"q":{"type":"noul"}}}"#.utf8)
private let relayMCPCall = Data(
    #"""
    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"jev_decide",
    "arguments":{"state":"synthetic","questions":{"q":{"type":"noul"}}}}}
    """#.utf8)

private func relayFailure(unknown: Bool) -> Data {
    Data(
        """
        {"error":{"origin":"relay","code":"relay_test_failure","message":"Synthetic relay failure","outcome_unknown":\(unknown)}}
        """.utf8)
}

@Test(arguments: [401, 429, 502, 504]) func relayErrorsPreserveOriginBodyAndAudit(status: Int) async throws {
    let unknown = status >= 500
    let body = relayFailure(unknown: unknown)
    let transport: JevClient.Transport = { request in
        (
            body,
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Falcon-Error-Origin": "relay"])!
        )
    }
    try await withFixture(upstreamTransport: transport) { fixture in
        for (path, method, input) in [("v1/systemone", "POST", relayInput as Data?), ("v1/models", "GET", nil)] {
            let reply = try await send(fixture, path: path, method: method, body: input, token: fixture.token)
            #expect(reply.status == status)
            #expect(reply.body == body)
            #expect(reply.response.value(forHTTPHeaderField: "X-Falcon-Error-Origin") == "relay")
        }
        let history = try await fixture.store.requests()
        #expect(history.count == 1)
        let summary = try #require(history.first)
        #expect(summary.errorCode == "relay_test_failure")
        #expect(summary.errorMessage == "Synthetic relay failure")
        #expect(summary.metadata["error_origin"] == "relay")
        #expect(summary.metadata["outcome_unknown"] == String(unknown))
        #expect(try await fixture.store.detail(id: summary.id)?.upstreamResponse == body)
        #expect(await fixture.calls.count == 2)
    }
}

@Test func relayMCPErrorRetainsUncertainOutcome() async throws {
    let transport: JevClient.Transport = { request in
        (
            relayFailure(unknown: true),
            HTTPURLResponse(
                url: request.url!, statusCode: 504, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Falcon-Error-Origin": "relay"])!
        )
    }
    try await withFixture(upstreamTransport: transport) { fixture in
        let reply = try await send(
            fixture, path: "mcp", body: relayMCPCall, token: fixture.token,
            headers: ["Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25"])
        let root = try JSONValue.decode(reply.body)
        let error = try #require(root["result"]?["structuredContent"]?["error"])
        #expect(error["origin"]?.stringValue == "relay")
        #expect(error["code"]?.stringValue == "relay_test_failure")
        #expect(error["outcome_unknown"]?.boolValue == true)
        #expect(error["retryable"]?.boolValue == false)
        #expect(await fixture.calls.count == 1)
    }
}

@Test func malformedRelayErrorsAreNormalizedOnlyForDelivery() async throws {
    let malformed = Data(#"{"error":{"origin":"relay","code":"","message":"Error","outcome_unknown":false}}"#.utf8)
    let transport: JevClient.Transport = { request in
        (
            malformed,
            HTTPURLResponse(
                url: request.url!, statusCode: 502, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Falcon-Error-Origin": "relay"])!
        )
    }
    try await withFixture(upstreamTransport: transport) { fixture in
        for (path, method, input) in [("v1/systemone", "POST", relayInput as Data?), ("v1/models", "GET", nil)] {
            let reply = try await send(fixture, path: path, method: method, body: input, token: fixture.token)
            let error = try #require(JSONValue.decode(reply.body)["error"])
            #expect(error["origin"]?.stringValue == "relay")
            #expect(error["code"]?.stringValue == "relay_invalid_error")
            #expect(error["outcome_unknown"]?.boolValue == true)
        }
        let mcp = try await send(
            fixture, path: "mcp", body: relayMCPCall, token: fixture.token,
            headers: ["Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25"])
        let error = try #require(JSONValue.decode(mcp.body)["result"]?["structuredContent"]?["error"])
        #expect(error["origin"]?.stringValue == "relay")
        #expect(error["code"]?.stringValue == "relay_invalid_error")
        #expect(error["outcome_unknown"]?.boolValue == true)
        for summary in try await fixture.store.requests() {
            #expect(try await fixture.store.detail(id: summary.id)?.upstreamResponse == malformed)
        }
        #expect(await fixture.calls.count == 3)
    }
}
