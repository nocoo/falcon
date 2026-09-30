import Foundation
import Testing

@testable import FalconCore

@Test func typeSafeModelsAuthenticateWithoutCreatingDecisions() async throws {
    try await withFixture { fixture in
        for authorization in ["Bearer", "bearer", "BEARER"] {
            let reply = try await send(
                fixture, path: "v1/models", method: "GET", token: nil,
                headers: ["Authorization": "\(authorization) \(fixture.token)"])
            #expect(reply.status == 200)
            #expect(
                try JSONValue.decode(reply.body)["models"]?.arrayValue?.first?["name"]?.stringValue == "jev-synthetic")
            #expect(reply.response.value(forHTTPHeaderField: "x-typesafe-request-id") == "synthetic-models")
            #expect(reply.response.value(forHTTPHeaderField: "X-Falcon-Request-ID") == nil)
        }
        let requests = await fixture.calls.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(
            requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-upstream-key" })
        for path in ["v1/models", "v1/systemone", "health", "mcp"] {
            let reply = try await send(fixture, path: path, method: "GET", token: nil)
            #expect(reply.status == 401)
            #expect(reply.response.value(forHTTPHeaderField: "WWW-Authenticate") == "Bearer")
        }
        for header in ["Basic \(fixture.token)", "Bearer ", "Bearer  \(fixture.token)", "Bearer synthetic-invalid"] {
            let reply = try await send(
                fixture, path: "v1/models", method: "GET", token: nil, headers: ["Authorization": header])
            #expect(reply.status == 401)
        }
        for method in ["POST", "DELETE", "OPTIONS", "HEAD"] {
            let reply = try await send(fixture, path: "v1/models", method: method, token: fixture.token)
            #expect(reply.status == 405)
            #expect(reply.response.value(forHTTPHeaderField: "Allow") == "GET")
        }
        let origin = try await send(
            fixture, path: "v1/models", method: "GET", token: fixture.token, headers: ["Origin": "null"])
        #expect(origin.status == 403)
        await fixture.service.pause()
        let paused = try await send(fixture, path: "v1/models", method: "GET", token: fixture.token)
        #expect(paused.status == 503)
        #expect(try JSONValue.decode(paused.body)["error"]?["request_id"] == nil)
        try await fixture.service.resume()
        var source = try #require(await fixture.store.sources().first)
        source.enabled = false
        try await fixture.configuration.saveSource(source)
        let disabled = try await send(fixture, path: "v1/models", method: "GET", token: fixture.token)
        #expect(disabled.status == 403)
        source.enabled = true
        try await fixture.configuration.saveSource(source)
        try await fixture.configuration.revokeKey(sourceID: source.id)
        let revoked = try await send(fixture, path: "v1/models", method: "GET", token: fixture.token)
        #expect(revoked.status == 401)
        #expect(await fixture.calls.count == 3)
        #expect(try await fixture.store.requests().isEmpty)
        #expect(await fixture.service.status().inFlight == 0)
    }
}

@Test func typeSafeModelsUseEachSourcesCurrentConnection() async throws {
    try await withFixture { fixture in
        let profile = try await fixture.configuration.saveProfile(
            UpstreamProfile(name: "Other", baseURL: "https://other.invalid/api"), apiKey: "synthetic-other-key")
        let issued = try await fixture.configuration.createSource(name: "Other", profileID: profile.id)
        let reply = try await send(fixture, path: "v1/models", method: "GET", token: issued.token)
        #expect(reply.status == 200)
        let request = try #require(await fixture.calls.requests.first)
        #expect(request.url?.absoluteString == "https://other.invalid/api/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-other-key")
        var disabled = profile
        disabled.enabled = false
        _ = try await fixture.configuration.saveProfile(disabled, apiKey: nil)
        let unavailable = try await send(fixture, path: "v1/models", method: "GET", token: issued.token)
        #expect(unavailable.status == 503)
        #expect(await fixture.calls.count == 1)
    }
}

@Test(arguments: [401, 422, 429, 529]) func typeSafeErrorsPreserveUpstreamBodyAndDiagnostics(status: Int) async throws {
    try await withFixture(upstreamStatus: status) { fixture in
        for (path, method, body) in [
            ("v1/models", "GET", nil as Data?),
            (
                "v1/systemone", "POST",
                Data(#"{"model":"jev-latest","state":"synthetic","questions":{"n":{"type":"noul"}}}"#.utf8)
            ),
        ] {
            let reply = try await send(fixture, path: path, method: method, body: body, token: fixture.token)
            #expect(reply.status == status)
            #expect(reply.body == Data(#"{"error":"synthetic upstream"}"#.utf8))
            #expect(reply.response.value(forHTTPHeaderField: "x-typesafe-request-id") == "synthetic-upstream-request")
            #expect(reply.response.value(forHTTPHeaderField: "retry-after-ms") == "2000")
            #expect(reply.response.value(forHTTPHeaderField: "Retry-After") == "2")
            #expect(reply.response.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(reply.response.value(forHTTPHeaderField: "Set-Cookie") == nil)
        }
        #expect(try await fixture.store.requests().count == 1)
        #expect(await fixture.calls.count == 2)
    }
}

@Test func typeSafeModelsTimeoutAndOversizedResponsesStayBounded() async throws {
    try await withFixture(upstreamDelay: .seconds(1), deadline: .milliseconds(50)) { fixture in
        let reply = try await send(fixture, path: "v1/models", method: "GET", token: fixture.token)
        #expect(reply.status == 504)
        #expect(await fixture.calls.count == 1)
        #expect(await fixture.service.status().inFlight == 0)
        #expect(try await fixture.store.requests().isEmpty)
    }
    try await withFixture(oversizedResponse: true) { fixture in
        let reply = try await send(fixture, path: "v1/models", method: "GET", token: fixture.token)
        #expect(reply.status == 502)
        #expect(try JSONValue.decode(reply.body)["error"]?["code"]?.stringValue == "upstream_response_too_large")
        #expect(await fixture.service.status().inFlight == 0)
        #expect(try await fixture.store.requests().isEmpty)
    }
}
