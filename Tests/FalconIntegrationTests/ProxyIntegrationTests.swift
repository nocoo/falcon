import Foundation
import HTTPTypes
import Hummingbird
import MCP
import Testing

@testable import FalconCore

struct ProxyFixture: Sendable {
    let store: DecisionStore
    let configuration: ConfigurationManager
    let service: DecisionService
    let server: ProxyServer
    let token: String
    let profileID: UUID
    let port: Int
    let calls: UpstreamCalls
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
}

actor UpstreamCalls {
    private(set) var count = 0
    private(set) var bodies: [Data] = []
    func next(_ body: Data) {
        count += 1
        bodies.append(body)
    }
}

private actor BoundPort {
    private var port: Int?
    private var waiter: CheckedContinuation<Int, Never>?
    func set(_ value: Int) {
        port = value
        waiter?.resume(returning: value)
        waiter = nil
    }
    func get() async -> Int {
        if let port { return port }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private actor FixtureRoutes {
    private(set) var redirected = 0
    func visitRedirected() { redirected += 1 }
}

private struct SyntheticUpstream: Sendable {
    let upstreamDelay: Duration
    let ignoreCancellation: Bool
    let oversizedResponse: Bool
    let upstreamStatus: Int
    let calls: UpstreamCalls

    func reply(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await calls.next(request.httpBody ?? Data())
        if ignoreCancellation {
            let hold = Task.detached { try await Task.sleep(for: upstreamDelay) }
            try await hold.value
        } else {
            try await Task.sleep(for: upstreamDelay)
        }
        if oversizedResponse {
            return (
                Data(repeating: 0x61, count: FalconLimits.responseBytes + 1),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
            )
        }
        if upstreamStatus != 200 {
            return (
                Data(#"{"error":"synthetic upstream"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: upstreamStatus, httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json", "Retry-After": "2", "Set-Cookie": "secret=synthetic",
                        "Authorization": "Bearer synthetic",
                    ])!
            )
        }
        let root = try JSONValue.decode(request.httpBody ?? Data()).objectValue!
        let questions = root["questions"]!.objectValue!
        var answers: [String: JSONValue] = [:]
        for (id, question) in questions { answers[id] = try Self.answer(question) }
        let body = try JSONValue.object([
            "model": .string("jev-synthetic"), "answers": .object(answers),
            "usage": .object(["input_tokens": .number(10), "output_tokens": .number(2)]),
            "echo": root["state"] ?? .null,
        ]).data()
        return (
            body,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    private static func answer(_ question: JSONValue) throws -> JSONValue {
        switch question["type"]?.stringValue {
        case "choice":
            let options = question["criteria"]!.objectValue!
            let winner = options.keys.sorted()[0]
            return .object([
                "type": .string("choice"), "choice": .string(winner),
                "probabilities": .object(
                    options.mapValues { _ in .number(0) }.merging([winner: .number(1)]) { _, new in new }),
                "confidence": .number(1),
            ])
        case "noul": return .object(["type": .string("noul"), "noul": .number(0.9)])
        case "score":
            let levels = question["criteria"]!.arrayValue!
            var legend: [String: JSONValue] = [:]
            var probabilities: [String: JSONValue] = [:]
            for (index, level) in levels.enumerated() {
                legend[String(index)] = level
                probabilities[String(index)] = .number(index == 0 ? 1 : 0)
            }
            return .object([
                "type": .string("score"), "score": .number(0), "legend": .object(legend),
                "probabilities": .object(probabilities), "confidence": .number(1),
            ])
        default: throw FalconError("fixture_invalid", "Fixture received invalid question")
        }
    }
}

func withFixture(
    upstreamDelay: Duration = .milliseconds(40), ignoreCancellation: Bool = false, deadline: Duration = .seconds(30),
    oversizedResponse: Bool = false, upstreamStatus: Int = 200, budgetBytes: Int64 = FalconLimits.storageBytes,
    _ work: (ProxyFixture) async throws -> Void
) async throws {
    let runID = UUID()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-proxy-\(runID.uuidString)")
    let store = try DecisionStore(
        path: directory.appendingPathComponent("fixture.sqlite").path, testRunID: runID, budgetBytes: budgetBytes)
    let configuration = ConfigurationManager(store: store, vault: .memory())
    let profile = try await configuration.saveProfile(
        UpstreamProfile(name: "Synthetic", baseURL: "https://fixture.invalid"), apiKey: "synthetic-upstream-key")
    let issued = try await configuration.createSource(name: "First", profileID: profile.id)
    let calls = UpstreamCalls()
    let upstream = SyntheticUpstream(
        upstreamDelay: upstreamDelay, ignoreCancellation: ignoreCancellation, oversizedResponse: oversizedResponse,
        upstreamStatus: upstreamStatus, calls: calls)
    let client = JevClient { request in try await upstream.reply(request) }
    let service = DecisionService(store: store, configuration: configuration, client: client, deadline: deadline)
    let server = ProxyServer(service: service, configuration: configuration, port: 0)
    let port = try await server.start()
    let fixture = ProxyFixture(
        store: store, configuration: configuration, service: service, server: server, token: issued.token,
        profileID: profile.id, port: port, calls: calls)
    var workError: Error?
    do { try await work(fixture) } catch { workError = error }
    await server.shutdown()
    guard try await store.testMarkerMatches(runID), directory.lastPathComponent == "falcon-proxy-\(runID.uuidString)"
    else { throw FalconError("test_marker_mismatch", "Refusing fixture cleanup") }
    try FileManager.default.removeItem(at: directory)
    if let workError { throw workError }
}

struct LoopbackReply: Sendable {
    let status: Int
    let body: Data
    let response: HTTPURLResponse
}

func send(
    _ fixture: ProxyFixture, path: String, method: String = "POST", body: Data? = nil, token: String?,
    headers: [String: String] = [:]
) async throws -> LoopbackReply {
    var request = URLRequest(url: fixture.base.appendingPathComponent(path))
    request.httpMethod = method
    request.httpBody = body
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    return LoopbackReply(status: http.statusCode, body: data, response: http)
}

private let threeQuestions = Data(
    #"""
    {"state":{"task":"synthetic"},"model":"jev-latest","extra_body":{"preserved":true},
    "questions":{"c":{"type":"choice","instructions":"choose","criteria":{"a":"A","b":"B"}},
    "n":{"type":"noul","instructions":"yes?"},
    "s":{"type":"score","instructions":"rate","criteria":["low","high"]}}}
    """#.utf8)

private func waitForFlight(_ service: DecisionService) async throws {
    for _ in 0..<200 {
        if await service.status().inFlight > 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FalconError("test_timeout", "Fixture request did not enter the decision service")
}

@Test func realLoopbackHTTPAndAudit() async throws {
    try await withFixture { fixture in
        #expect(await fixture.server.status().running)
        let loopbackReply1 = try await send(fixture, path: "health", method: "GET", token: fixture.token)
        let healthStatus = loopbackReply1.status
        #expect(healthStatus == 200)
        let loopbackReply2 = try await send(fixture, path: "health", method: "GET", token: nil)
        let unauthorized = loopbackReply2.status
        #expect(unauthorized == 401)
        let loopbackReply3 = try await send(
            fixture, path: "health", method: "GET", token: fixture.token, headers: ["Origin": "https://evil.invalid"])
        let forbidden = loopbackReply3.status
        #expect(forbidden == 403)
        let loopbackReply4 = try await send(
            fixture, path: "health", method: "GET", token: fixture.token, headers: ["Host": "evil.invalid"])
        let host = loopbackReply4.status
        #expect(host == 403)
        let loopbackReply5 = try await send(fixture, path: "mcp", method: "GET", token: fixture.token)
        let method = loopbackReply5.status
        let methodResponse = loopbackReply5.response
        #expect(method == 405)
        #expect(methodResponse.value(forHTTPHeaderField: "Allow") == "POST")
        let loopbackReply6 = try await send(fixture, path: "mcp", method: "DELETE", token: fixture.token)
        let delete = loopbackReply6.status
        #expect(delete == 405)
        let loopbackReply7 = try await send(fixture, path: "missing", method: "GET", token: fixture.token)
        let missing = loopbackReply7.status
        #expect(missing == 404)
        let loopbackReply8 = try await send(
            fixture, path: "mcp", body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), token: fixture.token,
            headers: ["Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "invalid"])
        let version = loopbackReply8.status
        #expect(version == 400)
        let loopbackReply9 = try await send(
            fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token,
            headers: ["Content-Type": "text/plain"])
        let media = loopbackReply9.status
        #expect(media == 415)
        let loopbackReply10 = try await send(
            fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token,
            headers: ["Content-Encoding": "gzip"])
        let encoding = loopbackReply10.status
        #expect(encoding == 415)
        let loopbackReply11 = try await send(
            fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token,
            headers: ["X-Falcon-Agent": "untrusted fixture"])
        let status = loopbackReply11.status
        let raw = loopbackReply11.body
        let response = loopbackReply11.response
        #expect(status == 200)
        #expect(try JSONValue.decode(raw)["answers"]?.objectValue?.count == 3)
        let id = try #require(UUID(uuidString: response.value(forHTTPHeaderField: "X-Falcon-Request-ID") ?? ""))
        let detail = try #require(await fixture.store.detail(id: id))
        #expect(detail.summary.status == .succeeded)
        #expect(detail.summary.delivery == .written)
        #expect(detail.summary.timing.deliveryFinishedMS != nil)
        #expect(detail.summary.metadata["X-Falcon-Agent"] == "untrusted fixture")
        #expect(detail.receivedRequest == threeQuestions)
        #expect(try JSONValue.decode(detail.effectiveRequest!)["extra_body"]?["preserved"]?.boolValue == true)
        #expect(await fixture.calls.count == 1)
        await fixture.service.pause()
        let loopbackReply12 = try await send(fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token)
        let paused = loopbackReply12.status
        #expect(paused == 503)
        try await fixture.service.resume()
    }
}

@Test func timeoutAndDisconnectDoNotRetryOrLeakReservations() async throws {
    try await withFixture(upstreamDelay: .milliseconds(200), deadline: .milliseconds(30)) { fixture in
        let loopbackReply13 = try await send(fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token)
        let timedOut = loopbackReply13.status
        let response = loopbackReply13.response
        #expect(timedOut == 504)
        let id = try #require(UUID(uuidString: response.value(forHTTPHeaderField: "X-Falcon-Request-ID") ?? ""))
        let detail = try #require(await fixture.store.detail(id: id))
        #expect(detail.summary.status == .timedOut)
        #expect(detail.summary.timing.responseReceivedMS == nil)
        let firstCalls = await fixture.calls.count
        #expect(firstCalls <= 1)
        #expect(await fixture.service.status().inFlight == 0)
        let loopbackReply14 = try await send(fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token)
        let again = loopbackReply14.status
        #expect(again == 504)
        let totalCalls = await fixture.calls.count
        #expect(totalCalls - firstCalls <= 1)
    }
    try await withFixture(upstreamDelay: .milliseconds(250)) { fixture in
        var request = URLRequest(url: fixture.base.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.httpBody = threeQuestions
        request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = URLSession.shared.dataTask(with: request)
        task.resume()
        try await waitForFlight(fixture.service)
        task.cancel()
        for _ in 0..<100 where await fixture.service.status().inFlight > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.service.status().inFlight == 0)
        let history = try await fixture.store.requests()
        #expect(history.count == 1)
        #expect(history[0].status == .succeeded)
        #expect((history[0].delivery == .written) == (history[0].timing.deliveryFinishedMS != nil))
        #expect(await fixture.calls.count == 1)
    }
}

@Test func oversizedAndStreamedBodyAreRejectedWithoutUpstreamCall() async throws {
    try await withFixture { fixture in
        let oversized = Data(repeating: 0x61, count: FalconLimits.requestBytes + 1)
        let loopbackReply15 = try await send(fixture, path: "v1/systemone", body: oversized, token: fixture.token)
        let first = loopbackReply15.status
        #expect(first == 413)
        var streamed = URLRequest(url: fixture.base.appendingPathComponent("v1/systemone"))
        streamed.httpMethod = "POST"
        streamed.httpBodyStream = InputStream(data: oversized)
        streamed.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        streamed.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, streamedResponse) = try await URLSession.shared.data(for: streamed)
        #expect((streamedResponse as? HTTPURLResponse)?.statusCode == 413)
        #expect(await fixture.calls.count == 0)
        let history = try await fixture.store.requests()
        #expect(history.count == 2)
        for summary in history {
            #expect(summary.status == .rejected)
            #expect(summary.errorCode == "request_too_large")
            #expect(summary.timing.bodyReceivedMS == nil)
            #expect(summary.metadata["body_complete"] == "false")
            let detail = try #require(await fixture.store.detail(id: summary.id))
            #expect(detail.receivedRequest == nil)
            #expect(detail.effectiveRequest == nil)
        }
        #expect(await fixture.service.status().state == .ready)
        let loopbackReply16 = try await send(fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token)
        let valid = loopbackReply16.status
        #expect(valid == 200)
    }
}

@Test func oversizedEffectiveOrReceivedBodyHasOnlyBoundedRejectionMetadata() async throws {
    try await withFixture { fixture in
        let prefix = #"{"state":""#
        let suffix = #"","questions":{"n":{"type":"noul","instructions":"yes?"}}}"#
        let padding = String(
            repeating: "a", count: FalconLimits.requestBytes - prefix.utf8.count - suffix.utf8.count - 1)
        let body = Data((prefix + padding + suffix).utf8)
        #expect(body.count == FalconLimits.requestBytes - 1)
        let reply = await fixture.service.submit(token: fixture.token, body: body, transport: .mcp)
        #expect(reply.status == 413)
        let summary = try #require(await fixture.store.requests().first)
        let detail = try #require(await fixture.store.detail(id: summary.id))
        #expect(summary.status == .rejected)
        #expect(summary.errorCode == "request_too_large")
        #expect(summary.timing.bodyReceivedMS == nil)
        #expect(summary.metadata["body_complete"] == "false")
        #expect(detail.receivedRequest == nil)
        #expect(detail.effectiveRequest == nil)
        #expect(await fixture.calls.count == 0)
        let oversizedReceived = Data(repeating: 0x61, count: FalconLimits.requestBytes + 1)
        let second = await fixture.service.submit(
            token: fixture.token, body: threeQuestions, receivedRequest: oversizedReceived, transport: .mcp)
        #expect(second.status == 413)
        let secondDetail = try #require(await fixture.store.detail(id: second.requestID!))
        #expect(secondDetail.receivedRequest == nil)
        #expect(secondDetail.effectiveRequest == nil)
        #expect(secondDetail.summary.timing.bodyReceivedMS == nil)
        #expect(await fixture.calls.count == 0)
        #expect(await fixture.service.status().state == .ready)
    }
}

@Test func stalledBodyStopsAtDeadline() async throws {
    let (body, source) = RequestBody.makeStream()
    defer { source.finish() }
    do {
        _ = try await ProxyServer.readBody(body, until: ContinuousClock().now.advanced(by: .milliseconds(30)))
        Issue.record("Stalled body was accepted")
    } catch let error as FalconError {
        #expect(error.code == "body_timeout")
        #expect(error.status == 408)
    }
}

@Test func globalConcurrencyIsReservedAfterConfigurationAwait() async throws {
    try await withFixture(upstreamDelay: .milliseconds(500)) { fixture in
        var tokens = [fixture.token]
        for index in 1..<5 {
            let source = try await fixture.configuration.createSource(
                name: "Source \(index)", profileID: fixture.profileID)
            tokens.append(source.token)
        }
        let pending = tokens.prefix(4).flatMap { token in
            (0..<2).map { _ in Task { await fixture.service.submit(token: token, body: threeQuestions) } }
        }
        for _ in 0..<100 {
            if await fixture.service.status().inFlight == 8 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.service.status().inFlight == 8)
        let rejected = await fixture.service.submit(token: tokens[4], body: threeQuestions)
        #expect(rejected.status == 429)
        for request in pending { #expect(await request.value.status == 200) }
        #expect(await fixture.calls.count == 8)
        #expect(await fixture.service.status().inFlight == 0)
    }
}

@Test func storagePressureRemainsRecoverableAndVisible() async throws {
    try await withFixture(budgetBytes: 3_000_000) { fixture in
        let reply = await fixture.service.submit(token: fixture.token, body: threeQuestions)
        #expect(reply.status == 507)
        #expect(reply.error?.code == "storage_full")
        #expect(await fixture.service.status().state == .ready)
        #expect(await fixture.service.status().storageRejections == 1)
        #expect(await fixture.calls.count == 0)
        let history = try await fixture.store.requests()
        #expect(history.isEmpty)
    }
}

@Test func receivedBodySizeIsIncludedInStorageReservation() async throws {
    try await withFixture(budgetBytes: 25_000_000) { fixture in
        let received = Data(repeating: 0x61, count: 900_000)
        let reply = await fixture.service.submit(
            token: fixture.token, body: threeQuestions, receivedRequest: received, transport: .mcp)
        #expect(reply.status == 507)
        #expect(reply.error?.code == "storage_full")
        #expect(await fixture.service.status().storageRejections == 1)
        #expect(await fixture.service.status().state == .ready)
        #expect(await fixture.calls.count == 0)
    }
}

@Test func incompleteAuditAndClearHistoryDoNotRace() async throws {
    try await withFixture { fixture in
        for _ in 0..<20 {
            let rejection = Task {
                await fixture.service.rejectIncomplete(
                    token: fixture.token, code: "request_too_large", status: 413, receivedAt: Date(),
                    receivedInstant: ContinuousClock().now)
            }
            let clearing = Task { try await fixture.service.clearHistory() }
            let reply = await rejection.value
            #expect(reply.status == 413 || reply.status == 503)
            try await clearing.value
            let history = try await fixture.store.requests()
            #expect(history.isEmpty)
            #expect(await fixture.service.status().state == .ready)
        }
        let beforeClear = ContinuousClock().now
        try await fixture.service.clearHistory()
        let late = await fixture.service.rejectIncomplete(
            token: fixture.token, code: "request_too_large", status: 413, receivedAt: Date(),
            receivedInstant: beforeClear)
        #expect(late.status == 503)
        let history = try await fixture.store.requests()
        #expect(history.isEmpty)
    }
}

@Test func elapsedPreparationPreventsLateUpstreamDispatch() async throws {
    try await withFixture(deadline: .milliseconds(20)) { fixture in
        let earlier = ContinuousClock().now.advanced(by: .milliseconds(-50))
        let reply = await fixture.service.submit(token: fixture.token, body: threeQuestions, receivedInstant: earlier)
        #expect(reply.status == 504)
        #expect(reply.error?.outcomeUnknown == false)
        #expect(await fixture.calls.count == 0)
        let summary = try #require(await fixture.store.requests().first)
        #expect(summary.status == .timedOut)
        #expect(summary.timing.upstreamStartedMS == nil)
    }
}

@Test func officialMCPClientCompletesCrossPostSequence() async throws {
    try await withFixture { fixture in
        let transport = HTTPClientTransport(
            endpoint: fixture.base.appendingPathComponent("mcp"), streaming: false,
            requestModifier: { request in
                var request = request
                request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
                return request
            })
        let client = Client(name: "FalconFixture", version: "1")
        _ = try await client.connect(transport: transport)
        try await client.ping()
        let listed = try await client.listTools()
        #expect(listed.tools.map(\.name) == ["jev_decide"])
        var choice: [String: Value] = ["type": .string("choice"), "instructions": .string("choose")]
        choice["criteria"] = .object(["a": .string("A"), "b": .string("B")])
        let arguments: [String: Value] = ["state": .string("synthetic"), "questions": .object(["c": .object(choice)])]
        let result = try await client.callTool(name: "jev_decide", arguments: arguments)
        #expect(result.isError == false)
        #expect(result.content.count == 1)
        #expect(await fixture.calls.count == 1)
        await client.disconnect()
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FALCON_PYTHON"] != nil))
func officialPythonSDKCallsRealLoopback() async throws {
    try await withFixture { fixture in
        let interpreter = try #require(ProcessInfo.processInfo.environment["FALCON_PYTHON"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/check-sdk-fixture.py")
        process.arguments = [script.path]
        process.environment = [
            "FALCON_TEST_BASE_URL": fixture.base.absoluteString, "FALCON_TEST_TOKEN": fixture.token,
            "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = try #require(String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        #expect(process.terminationStatus == 0, "\(message)")
        #expect(message.contains("python-sdk-ok"))
        let summary = try #require(await fixture.store.requests().first)
        let detail = try #require(await fixture.store.detail(id: summary.id))
        #expect(summary.status == .succeeded)
        #expect(summary.questionCount == 3)
        for body in [detail.receivedRequest, detail.effectiveRequest] {
            let json = try JSONValue.decode(#require(body))
            #expect(json["extension"]?["kept"]?.boolValue == true)
            #expect(json["questions"]?["n"]?["custom_question"]?["kept"]?.boolValue == true)
        }
        #expect(await fixture.calls.count == 1)
    }
}

@Test func concurrentSameMCPIDHasIndependentSources() async throws {
    try await withFixture { fixture in
        let second = try await fixture.configuration.createSource(name: "Second", profileID: fixture.profileID)
        let body = Data(
            #"""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
            "name":"jev_decide","arguments":{"state":"synthetic",
            "questions":{"n":{"type":"noul","instructions":"yes?"}}}}}
            """#.utf8)
        async let first = send(
            fixture, path: "mcp", body: body, token: fixture.token,
            headers: ["Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25"])
        async let other = send(
            fixture, path: "mcp", body: body, token: second.token,
            headers: ["Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25"])
        let responses = try await [first, other]
        #expect(responses.allSatisfy { $0.status == 200 })
        let ids = try responses.map { response -> String in
            let root = try JSONValue.decode(response.body)
            #expect(root["id"]?.numberValue == 1)
            return try #require(root["result"]?["structuredContent"]?["request_id"]?.stringValue)
        }
        #expect(Set(ids).count == 2)
        let history = try await fixture.store.requests()
        #expect(history.count == 2)
        #expect(Set(history.map(\.sourceID)).count == 2)
        #expect(await fixture.calls.count == 2)
    }
}

@Test func clearHistoryWaitsForInFlightAndCannotResurrect() async throws {
    try await withFixture(upstreamDelay: .milliseconds(300)) { fixture in
        let pending = Task { try await send(fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token) }
        try await waitForFlight(fixture.service)
        let clearing = Task { try await fixture.service.clearHistory() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fixture.service.status().state == .paused)
        let during = try await fixture.store.requests()
        #expect(during.count == 1)
        let completed = try await pending.value
        #expect(completed.status == 200)
        try await clearing.value
        let cleared = try await fixture.store.requests()
        #expect(cleared.isEmpty)
        let id = try #require(
            UUID(uuidString: completed.response.value(forHTTPHeaderField: "X-Falcon-Request-ID") ?? ""))
        await fixture.service.deliveryWritten(id: id, since: ContinuousClock().now)
        let afterCallback = try await fixture.store.requests()
        #expect(afterCallback.isEmpty)
        #expect(await fixture.service.status().state == .ready)
        #expect(await fixture.calls.count == 1)
    }
}

@Test func shutdownKeepsLateUpstreamResultInterrupted() async throws {
    try await withFixture(upstreamDelay: .milliseconds(350), ignoreCancellation: true) { fixture in
        let pending = Task { await fixture.service.submit(token: fixture.token, body: threeQuestions) }
        try await waitForFlight(fixture.service)
        await fixture.service.shutdown(grace: .milliseconds(30))
        let reply = await pending.value
        #expect(reply.status == 503)
        let history = try await fixture.store.requests()
        #expect(history.count == 1)
        #expect(history[0].status == .interrupted)
        #expect(history[0].delivery == .unknown)
        await fixture.service.deliveryWritten(id: history[0].id, since: ContinuousClock().now)
        await fixture.service.deliveryFailed(id: history[0].id)
        let afterCallback = try #require(await fixture.store.detail(id: history[0].id))
        #expect(afterCallback.summary.delivery == .unknown)
        #expect(afterCallback.summary.timing.deliveryFinishedMS == nil)
        #expect(await fixture.service.status().state == .paused)
        #expect(await fixture.calls.count == 1)
    }
}

@Test func realURLSessionRefusesRedirectAndBoundsStreamedResponse() async throws {
    let bound = BoundPort()
    let routes = FixtureRoutes()
    let chunk = ByteBuffer(bytes: Data(repeating: 0x61, count: 65_536))
    let responder = CallbackResponder<BasicRequestContext> { request, _ in
        switch request.uri.path {
        case "/v1/systemone":
            let port = await bound.get()
            var fields = HTTPFields()
            fields[HTTPField.Name("Location")!] = "http://127.0.0.1:\(port)/redirected"
            return Hummingbird.Response(status: .init(code: 302), headers: fields)
        case "/redirected":
            await routes.visitRedirected()
            return Hummingbird.Response(status: .ok)
        case "/large":
            let body = ResponseBody { writer in
                for _ in 0..<65 { try await writer.write(chunk) }
                try await writer.finish(nil)
            }
            return Hummingbird.Response(status: .ok, body: body)
        default: return Hummingbird.Response(status: .notFound)
        }
    }
    let app = Application(
        responder: responder, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
        onServerRunning: { channel in await bound.set(channel.localAddress!.port!) })
    let server = Task { try await app.run() }
    let port = await bound.get()
    let source = AgentSource(name: "Synthetic", profileID: UUID())
    let identity = SourceIdentity(source: source, keyID: UUID())
    let profile = UpstreamProfile(id: source.profileID, name: "Synthetic", baseURL: "http://127.0.0.1:\(port)")
    let client = JevClient()
    func snapshot(_ path: String) -> ExecutionSnapshot {
        ExecutionSnapshot(
            identity: identity, profile: profile, endpoint: URL(string: "http://127.0.0.1:\(port)\(path)")!,
            credential: "synthetic-upstream-key")
    }
    do {
        _ = try await client.send(threeQuestions, snapshot: snapshot("/v1/systemone"))
        Issue.record("Redirect was accepted")
    } catch let error as FalconError { #expect(error.code == "upstream_redirect") }
    #expect(await routes.redirected == 0)
    do {
        _ = try await client.send(threeQuestions, snapshot: snapshot("/large"))
        Issue.record("Oversized response was accepted")
    } catch let error as JevResponseLimitError { #expect(error.prefix.count <= 4_096) }
    server.cancel()
    _ = await server.result
}

@Test func upstreamErrorsAndOversizedResponsePreserveAuditBoundary() async throws {
    try await withFixture(upstreamStatus: 429) { fixture in
        let loopbackReply17 = try await send(fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token)
        let status = loopbackReply17.status
        let body = loopbackReply17.body
        let response = loopbackReply17.response
        #expect(status == 429)
        #expect(String(bytes: body, encoding: .utf8) == #"{"error":"synthetic upstream"}"#)
        #expect(response.value(forHTTPHeaderField: "Retry-After") == "2")
        #expect(response.value(forHTTPHeaderField: "Set-Cookie") == nil)
        #expect(response.value(forHTTPHeaderField: "Authorization") == nil)
        let summary = try #require(await fixture.store.requests().first)
        #expect(summary.status == .upstreamError)
        #expect(summary.httpStatus == 429)
        #expect(await fixture.calls.count == 1)
    }
    try await withFixture(oversizedResponse: true) { fixture in
        let loopbackReply18 = try await send(fixture, path: "v1/systemone", body: threeQuestions, token: fixture.token)
        let status = loopbackReply18.status
        let response = loopbackReply18.response
        #expect(status == 502)
        let id = try #require(UUID(uuidString: response.value(forHTTPHeaderField: "X-Falcon-Request-ID") ?? ""))
        let detail = try #require(await fixture.store.detail(id: id))
        #expect(detail.summary.status == .invalidResponse)
        #expect(detail.summary.errorCode == "upstream_response_too_large")
        #expect(detail.summary.metadata["response_complete"] == "false")
        #expect(detail.upstreamResponse?.count == 4_096)
        #expect(await fixture.calls.count == 1)
    }
}
