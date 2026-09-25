import Foundation
import Testing

@testable import FalconCore

@Test func realHTTPAndMCPPreserveNumericEvidence() async throws {
    try await withFixture { fixture in
        let samples = [
            ("v1/systemone", "9007199254740992"), ("v1/systemone", "9007199254740993"), ("mcp", "9007199254740993.0"),
        ]
        for (path, identifier) in samples {
            let model = path == "mcp" ? "" : #""model":"jev-latest","#
            let numbers = [
                identifier, "12345678901234567890123456789012345678901234567890",
                "0.12345678901234567890123456789012345678901234567890", "1e-999",
            ]
            let arguments = """
                {\(model)"state":{"numbers":[\(numbers.joined(separator: ","))]},
                "questions":{"s":{"type":"score","instructions":{"id":\(identifier)},
                "criteria":[{"id":\(identifier)},"other"]}}}
                """
            let wire =
                path == "mcp"
                ? """
                {"jsonrpc":"2.0","id":7,"method":"tools/call",
                "params":{"name":"jev_decide","arguments":\(arguments)}}
                """ : arguments
            let reply = try await send(
                fixture, path: path, body: Data(wire.utf8), token: fixture.token,
                headers: ["Accept": "application/json, text/event-stream"])
            #expect(reply.status == 200)
            let forwarded = try #require(await fixture.calls.bodies.last)
            for literal in numbers {
                #expect((try #require(String(data: forwarded, encoding: .utf8))).contains(literal))
            }
            let result = try JSONValue.decode(reply.body)
            let response = path == "mcp" ? result["result"]?["structuredContent"]?["response"] : result
            let echo = try #require(response?["echo"]?["numbers"]?.arrayValue)
            #expect(echo.map(\.displayText) == numbers)
            if path == "mcp" {
                let text = try #require(result["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
                for literal in numbers { #expect(text.contains(literal)) }
            }
            let newest = try #require(try await fixture.store.requests().first)
            let detail = try #require(try await fixture.store.detail(id: newest.id))
            #expect(detail.receivedRequest == Data(wire.utf8))
            #expect(detail.effectiveRequest == forwarded)
            let presentation = DecisionPresentation(detail: detail)
            #expect(presentation.state?.displayText.contains(identifier) == true)
        }
        let usage = try await fixture.store.usage()
        #expect(usage.decisionGroups.count == 2)
        #expect(usage.decisionGroups.map(\.samples).sorted() == [1, 2])
    }
}
