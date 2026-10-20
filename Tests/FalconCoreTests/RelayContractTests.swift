import Foundation
import Testing

@testable import FalconCore

@Test(arguments: [
    "not json", "{}", #"{"error":{"origin":"upstream"}}"#,
    #"{"error":{"origin":"relay","code":"","message":"Error","outcome_unknown":false}}"#,
    #"{"error":{"origin":"relay","code":"relay_failed","message":"Error","outcome_unknown":"false"}}"#,
]) func relayMalformedErrorsStayUncertain(body: String) {
    let response = JevHTTPResult(status: 502, body: Data(body.utf8), errorOrigin: "relay")
    #expect(response.relayError?.code == "relay_invalid_error")
    #expect(response.relayError?.outcomeUnknown == true)
    #expect(DecisionService.upstreamHeaders(response)["X-Falcon-Error-Origin"] == "relay")
}

@Test func relayMarkersCannotReclassifySuccessOrUnknownOrigins() {
    for origin in [nil, "upstream", "falcon", "untrusted"] as [String?] {
        let response = JevHTTPResult(status: 502, body: Data(), errorOrigin: origin)
        #expect(response.relayError == nil)
        #expect(DecisionService.upstreamHeaders(response)["X-Falcon-Error-Origin"] == "upstream")
    }
    let success = JevHTTPResult(status: 200, body: Data(), errorOrigin: "relay")
    #expect(success.relayError == nil)
    #expect(DecisionService.upstreamHeaders(success)["X-Falcon-Error-Origin"] == nil)
}

@Test func relayConnectionSendsOnlyItsConfiguredCredential() async throws {
    let profile = UpstreamProfile(name: "Relay", baseURL: "https://relay.invalid")
    let source = AgentSource(name: "Synthetic", profileID: profile.id)
    let snapshot = ExecutionSnapshot(
        identity: SourceIdentity(source: source, keyID: UUID()), profile: profile,
        endpoint: URL(string: profile.baseURL + "/v1/systemone")!, credential: "synthetic-relay-token")
    let input = Data(#"{"number":9007199254740993,"optional":null}"#.utf8)
    let client = JevClient { request in
        #expect(request.url == snapshot.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == input)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-relay-token")
        #expect(request.value(forHTTPHeaderField: "X-Falcon-Agent") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        return (
            input,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
    #expect(try await client.send(input, snapshot: snapshot).body == input)
}
