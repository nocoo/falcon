import Foundation

struct MCPEnvelope: Sendable {
    let request: Data
    let arguments: Data?

    init(_ body: Data) throws {
        guard var root = try JSONValue.decode(body).objectValue, root["method"]?.stringValue == "tools/call",
            var params = root["params"]?.objectValue, let arguments = params["arguments"], arguments.objectValue != nil
        else {
            request = body
            arguments = nil
            return
        }
        self.arguments = try arguments.data()
        // MCP.Value uses Int/Double. Keep tool payloads out of its numeric conversion.
        params["arguments"] = .object([:])
        root["params"] = .object(params)
        request = try JSONValue.object(root).data()
    }
}

actor MCPDelivery {
    private var record: (UUID, ContinuousClock.Instant)?
    private var payload: JSONValue?

    func set(reply: ProxyReply, payload: JSONValue) {
        if let id = reply.requestID, let instant = reply.receivedInstant { record = (id, instant) }
        self.payload = payload
    }

    func value() -> (UUID, ContinuousClock.Instant)? { record }

    func responseBody(_ data: Data) throws -> Data {
        guard let payload, var root = try JSONValue.decode(data).objectValue, var result = root["result"]?.objectValue
        else { return data }
        result["structuredContent"] = payload
        root["result"] = .object(result)
        return try JSONValue.object(root).data()
    }
}
