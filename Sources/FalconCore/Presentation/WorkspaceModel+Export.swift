import Foundation

extension WorkspaceModel {
    public func exportJSON() async throws -> Data {
        guard let id = selectedID, isActive, !isSelecting else {
            throw FalconError("no_selection", "Wait for the selected decision to finish loading.")
        }
        guard timeline == nil else {
            throw FalconError("replay_export", "Show the final result before exporting the complete record.")
        }
        let record = try await store.detail(id: id)
        guard let record, record.summary.isRetained(at: Date()) else {
            throw FalconError("expired", "The decision is no longer available.")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let summary = try JSONValue.decode(encoder.encode(record.summary))
        func evidence(_ bytes: Data?) -> JSONValue {
            guard let bytes else { return .null }
            return .object([
                "json": (try? JSONValue.decode(bytes)) ?? .null,
                "original_base64": .string(bytes.base64EncodedString()),
            ])
        }
        return try JSONValue.object([
            "summary": summary, "received_request": evidence(record.receivedRequest),
            "effective_request": evidence(record.effectiveRequest),
            "upstream_response": evidence(record.upstreamResponse),
        ]).data(pretty: true)
    }

    public func exportCSV() async throws -> String {
        guard isActive else { throw FalconError("inactive", "Return to Falcon before exporting.") }
        var records: [RequestSummary] = []
        var cursor: RequestCursor?
        let query = filter
        repeat {
            let page = try await store.requests(filter: query, before: cursor)
            records += page
            guard records.count <= 10_000 else {
                throw FalconError("export_limit", "Narrow the range to 10,000 decisions or fewer.")
            }
            if page.count < 100 { break }
            cursor = page.last.map { RequestCursor(receivedAt: $0.receivedAt, id: $0.id) }
        } while cursor != nil
        return DecisionFormat.csv(records.filter { $0.isRetained(at: Date()) })
    }
}
