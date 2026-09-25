import Testing

@testable import FalconCore

@Test func proxyImmediatelyRebindsAfterHTTPShutdown() async throws {
    try await withFixture { fixture in
        let initial = try await send(
            fixture, path: "health", method: "GET", token: fixture.token, headers: ["Connection": "close"])
        #expect(initial.status == 200)
        await fixture.server.shutdown()
        let replacement = ProxyServer(
            service: fixture.service, configuration: fixture.configuration, version: "9.8.7", port: fixture.port)
        do {
            let port = try await replacement.start()
            #expect(port == fixture.port)
            let reply = try await send(fixture, path: "health", method: "GET", token: fixture.token)
            #expect(reply.status == 200)
        } catch {
            await replacement.shutdown()
            throw error
        }
        await replacement.shutdown()
    }
}

@Test func proxyRejectsASecondListenerOnTheSamePort() async throws {
    try await withFixture { fixture in
        let competitor = ProxyServer(
            service: fixture.service, configuration: fixture.configuration, version: "9.8.7", port: fixture.port)
        await #expect(throws: (any Error).self) { try await competitor.start() }
        await competitor.shutdown()
        let reply = try await send(fixture, path: "health", method: "GET", token: fixture.token)
        #expect(reply.status == 200)
    }
}
