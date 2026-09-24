import Foundation
import Hummingbird
import HTTPTypes
import MCP

public struct ProxyServerStatus: Sendable {
    public let running: Bool
    public let port: Int?
}

public actor ProxyServer {
    private let service: DecisionService
    private let configuration: ConfigurationManager
    private let port: Int
    private var boundPort: Int?
    private var task: Task<Void, Error>?
    private var bindWaiters: [CheckedContinuation<Int, Error>] = []

    public init(service: DecisionService, configuration: ConfigurationManager, port: Int = FalconLimits.port) {
        self.service = service
        self.configuration = configuration
        self.port = port
    }

    public func status() -> ProxyServerStatus { .init(running: boundPort != nil, port: boundPort) }

    public func start() async throws -> Int {
        if task == nil {
            let responder = CallbackResponder<BasicRequestContext> { request, _ in
                await self.respond(request)
            }
            let app = Application(responder: responder,
                                  configuration: .init(address: .hostname("127.0.0.1", port: port), reuseAddress: false),
                                  onServerRunning: { channel in await self.didBind(channel.localAddress?.port) })
            task = Task {
                do {
                    try await app.run()
                    self.didStop(nil)
                } catch {
                    self.didStop(error)
                    throw error
                }
            }
        }
        if let boundPort { return boundPort }
        return try await withCheckedThrowingContinuation { bindWaiters.append($0) }
    }

    public func run() async throws {
        _ = try await start()
        try await task?.value
    }

    public func shutdown() async {
        task?.cancel()
        _ = await task?.result
        task = nil
    }

    private func didBind(_ actualPort: Int?) {
        guard let actualPort else { return }
        boundPort = actualPort
        bindWaiters.forEach { $0.resume(returning: actualPort) }
        bindWaiters.removeAll()
    }

    private func didStop(_ error: Error?) {
        boundPort = nil
        let failure = error ?? FalconError("proxy_stopped", "Proxy stopped", status: 503)
        bindWaiters.forEach { $0.resume(throwing: failure) }
        bindWaiters.removeAll()
        task = nil
    }

    private func respond(_ request: Hummingbird.Request) async -> Hummingbird.Response {
        let started = ContinuousClock().now
        let receivedAt = Date()
        let expectedHost = "127.0.0.1:\(boundPort ?? port)"
        guard request.head.authority == expectedHost else { return Self.failure(403, "invalid_host") }
        if let origin = request.headers[.origin], origin != "http://\(expectedHost)" {
            return Self.failure(403, "invalid_origin")
        }
        guard let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer "),
              !authorization.dropFirst(7).isEmpty else { return Self.failure(401, "unauthorized") }
        let token = String(authorization.dropFirst(7))
        do { _ = try await configuration.authenticate(token: token) }
        catch let error as FalconError where error.status == 403 { return Self.failure(403, "source_disabled") }
        catch { return Self.failure(401, "unauthorized") }

        let path = request.uri.path
        if path == "/health" {
            guard request.method == .get else { return Self.methodNotAllowed("GET") }
            let status = await service.status()
            let body = (try? JSONValue.object(["status": .string(status.state.rawValue), "api_version": .string("1")]).data()) ?? Data()
            return Self.response(status.state == .ready ? 200 : 503, body: body)
        }
        guard path == "/v1/systemone" || path == "/mcp" else { return Self.failure(404, "not_found") }
        guard request.method == .post else { return Self.methodNotAllowed("POST") }
        let contentType = request.headers[.contentType]?.lowercased() ?? ""
        guard contentType == "application/json" || contentType.hasPrefix("application/json;") else {
            return Self.failure(415, "unsupported_media_type")
        }
        let encodingName = HTTPField.Name("Content-Encoding")!
        guard request.headers[encodingName] == nil || request.headers[encodingName]?.lowercased() == "identity" else {
            return Self.failure(415, "unsupported_encoding")
        }
        let metadata = Self.metadata(request.headers)
        guard (try? JSONValue.object(metadata.mapValues(JSONValue.string)).data().count) ?? 0 <= 4096 else {
            return Self.failure(413, "metadata_too_large")
        }
        let body: Data
        do {
            body = try await Self.readBody(request.body, until: started.advanced(by: .seconds(30)))
        } catch {
            let failure = error as? FalconError
            let reply = await service.rejectIncomplete(token: token, code: failure?.code ?? "body_incomplete",
                                                       status: failure?.status ?? 400,
                                                       metadata: metadata, receivedAt: receivedAt, receivedInstant: started)
            return Self.response(reply, service: service)
        }
        if path == "/mcp" {
            return await mcp(request: request, body: body, token: token, receivedAt: receivedAt, started: started)
        }
        let reply = await service.submit(token: token, body: body, metadata: metadata,
                                         receivedAt: receivedAt, receivedInstant: started)
        return Self.response(reply, service: service)
    }

    private func mcp(request: Hummingbird.Request, body: Data, token: String,
                     receivedAt: Date, started: ContinuousClock.Instant) async -> Hummingbird.Response {
        let versionName = HTTPField.Name("MCP-Protocol-Version")!
        let version = request.headers[versionName] ?? "2025-03-26"
        guard Version.supported.contains(version) else { return Self.failure(400, "unsupported_mcp_version") }
        let transport = StatelessHTTPServerTransport()
        let server = Server(name: "Falcon", version: "1", capabilities: .init(tools: .init()), configuration: .default)
        let delivery = MCPDelivery()
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [Self.tool])
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "jev_decide", let arguments = params.arguments else {
                throw MCPError.invalidParams("Unknown tool or missing arguments")
            }
            let argumentData = try JSONEncoder().encode(Value.object(arguments))
            let reply = await self.service.submit(token: token, body: argumentData,
                                                  receivedRequest: body, transport: .mcp,
                                                  metadata: Self.metadata(request.headers),
                                                  receivedAt: receivedAt, receivedInstant: started)
            if let id = reply.requestID, let instant = reply.receivedInstant {
                await delivery.set(id: id, instant: instant)
            }
            let result: JSONValue
            if reply.status >= 400 {
                let origin = reply.error == nil ? "upstream" : "falcon"
                let error = reply.error ?? FalconError("upstream_http_\(reply.status)", "Upstream returned HTTP \(reply.status)", status: reply.status)
                result = .object(["request_id": .string(reply.requestID?.uuidString ?? ""),
                                  "error": .object(["origin": .string(origin), "code": .string(error.code),
                                                    "message": .string(error.message), "retryable": .bool(false),
                                                    "outcome_unknown": .bool(error.outcomeUnknown)])])
            } else {
                result = .object(["request_id": .string(reply.requestID?.uuidString ?? ""),
                                  "response": (try? JSONValue.decode(reply.body)) ?? .null])
            }
            return try CallTool.Result(content: [.text(text: String(decoding: (try? result.data()) ?? Data(), as: UTF8.self),
                                                    annotations: nil, _meta: nil)],
                                   structuredContent: try Value(result), isError: reply.status >= 400)
        }
        do { try await server.start(transport: transport) }
        catch { return Self.failure(500, "mcp_unavailable") }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(35))
            if !Task.isCancelled { await transport.disconnect() }
        }
        var headers = ["Accept": request.headers[.accept] ?? "", "Content-Type": request.headers[.contentType] ?? ""]
        headers["MCP-Protocol-Version"] = version
        if let origin = request.headers[.origin] { headers["Origin"] = origin }
        let result = await transport.handleRequest(MCP.HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp"))
        timeout.cancel()
        await server.stop()
        await transport.disconnect()
        var responseHeaders = result.headers
        responseHeaders.removeValue(forKey: "Mcp-Session-Id")
        let record = await delivery.value()
        return Self.response(result.statusCode, body: result.bodyData ?? Data(), headers: responseHeaders,
                             delivery: record, service: service)
    }

    private static let tool: Tool = {
        let structured: JSONValue = .object(["oneOf": .array(["string", "object", "array"].map { .object(["type": .string($0)]) })])
        let description: JSONValue = .object(["oneOf": .array(["string", "object", "array", "null"].map { .object(["type": .string($0)]) })])
        let variants: [JSONValue] = [
            .object(["type": .string("object"), "required": .array([.string("type"), .string("instructions"), .string("criteria")]),
                     "properties": .object(["type": .object(["const": .string("choice")]),
                                            "instructions": structured,
                                            "criteria": .object(["type": .string("object"), "minProperties": .number(2),
                                                                 "maxProperties": .number(255), "additionalProperties": description])]),
                     "additionalProperties": .bool(true)]),
            .object(["type": .string("object"), "required": .array([.string("type"), .string("instructions")]),
                     "properties": .object(["type": .object(["const": .string("noul")]),
                                            "instructions": structured,
                                            "criteria": .object(["type": .string("object"),
                                                                 "required": .array([.string("true"), .string("false")]),
                                                                 "properties": .object(["true": description, "false": description]),
                                                                 "additionalProperties": .bool(false)])]),
                     "additionalProperties": .bool(true)]),
            .object(["type": .string("object"), "required": .array([.string("type"), .string("instructions"), .string("criteria")]),
                     "properties": .object(["type": .object(["const": .string("score")]),
                                            "instructions": structured,
                                            "criteria": .object(["type": .string("array"), "minItems": .number(2),
                                                                 "maxItems": .number(10), "items": description])]),
                     "additionalProperties": .bool(true)])
        ]
        let schema: JSONValue = .object([
            "type": .string("object"), "required": .array([.string("state"), .string("questions")]),
            "properties": .object([
                "state": structured,
                "model": .object(["type": .string("string")]),
                "questions": .object(["type": .string("object"), "additionalProperties": .object([
                    "oneOf": .array(variants)])])
            ]), "additionalProperties": .bool(true)
        ])
        let output: JSONValue = .object(["type": .string("object"),
                                         "properties": .object(["request_id": .object(["type": .string("string")]),
                                                                "response": .object(["type": .string("object")]),
                                                                "error": .object(["type": .string("object")])]),
                                         "oneOf": .array([
                                            .object(["required": .array([.string("request_id"), .string("response")])]),
                                            .object(["required": .array([.string("request_id"), .string("error")])])
                                         ])])
        return Tool(name: "jev_decide", description: "Ask Jev for a typed decision. Model output is not execution permission.",
                    inputSchema: try! Value(schema), outputSchema: try! Value(output))
    }()

    private static func metadata(_ headers: HTTPFields) -> [String: String] {
        var metadata: [String: String] = [:]
        for name in ["X-Falcon-Agent", "X-Falcon-Project", "X-Falcon-Run-ID"] {
            if let value = headers[HTTPField.Name(name)!] { metadata[name] = value }
        }
        return metadata
    }

    static func readBody(_ stream: RequestBody, until deadline: ContinuousClock.Instant) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var body = Data()
                for try await chunk in stream {
                    guard chunk.readableBytes <= FalconLimits.requestBytes - body.count else {
                        throw FalconError("request_too_large", "Request body exceeded limit", status: 413)
                    }
                    body.append(contentsOf: chunk.readableBytesView)
                }
                return body
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: ContinuousClock())
                throw FalconError("body_timeout", "Request body deadline exceeded", status: 408)
            }
            let body = try await group.next()!
            group.cancelAll()
            return body
        }
    }

    private static func methodNotAllowed(_ allow: String) -> Hummingbird.Response {
        response(405, body: Data(), headers: ["Allow": allow])
    }

    private static func failure(_ status: Int, _ code: String) -> Hummingbird.Response {
        let object: JSONValue = .object(["error": .object(["origin": .string("falcon"), "code": .string(code),
                                                             "message": .string(code), "outcome_unknown": .bool(false)])])
        return response(status, body: (try? object.data()) ?? Data())
    }

    private static func response(_ reply: ProxyReply, service: DecisionService) -> Hummingbird.Response {
        var headers = reply.headers
        if let id = reply.requestID { headers["X-Falcon-Request-ID"] = id.uuidString }
        if reply.error?.code == "falcon_busy" { headers["Retry-After"] = "1" }
        return response(reply.status, body: reply.body, headers: headers,
                        delivery: reply.requestID.flatMap { id in reply.receivedInstant.map { (id, $0) } }, service: service)
    }

    private static func response(_ status: Int, body: Data, headers: [String: String] = [:],
                                 delivery: (UUID, ContinuousClock.Instant)? = nil,
                                 service: DecisionService? = nil) -> Hummingbird.Response {
        var fields = HTTPFields()
        fields[.contentType] = headers["Content-Type"] ?? "application/json"
        for (name, value) in headers where name != "Content-Type" {
            if let field = HTTPField.Name(name) { fields[field] = value }
        }
        let bytes = ByteBuffer(bytes: body)
        let responseBody = ResponseBody(contentLength: body.count) { writer in
            do {
                if !body.isEmpty { try await writer.write(bytes) }
                try await writer.finish(nil)
                if let (id, instant) = delivery { await service?.deliveryWritten(id: id, since: instant) }
            } catch {
                if let (id, _) = delivery { await service?.deliveryFailed(id: id) }
                throw error
            }
        }
        return Hummingbird.Response(status: .init(code: status), headers: fields, body: responseBody)
    }
}

private actor MCPDelivery {
    private var record: (UUID, ContinuousClock.Instant)?
    func set(id: UUID, instant: ContinuousClock.Instant) { record = (id, instant) }
    func value() -> (UUID, ContinuousClock.Instant)? { record }
}
