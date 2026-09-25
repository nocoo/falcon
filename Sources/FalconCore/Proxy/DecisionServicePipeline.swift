import Foundation

extension DecisionService {
    func endFlight(sourceID: UUID, id: UUID) {
        inFlight[sourceID, default: 1] -= 1
        if inFlight[sourceID] == 0 { inFlight[sourceID] = nil }
        pendingIDs.remove(id)
    }

    func incompleteStatus(since instant: ContinuousClock.Instant, requireRunning: Bool) -> FalconError? {
        if storageFault { return FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507) }
        if predatesClear(instant) {
            return FalconError("history_cleared", "Request arrived before history was cleared", status: 503)
        }
        if requireRunning && (paused || stopping) {
            return FalconError("falcon_paused", "Proxy is paused", status: 503)
        }
        return nil
    }

    func sendUpstream(_ body: Data, snapshot: ExecutionSnapshot, id: UUID, since instant: ContinuousClock.Instant)
        async throws -> JevHTTPResult
    {
        let remaining = deadline - instant.duration(to: ContinuousClock().now)
        guard remaining > .zero else {
            throw FalconError("upstream_timeout", "Request deadline exceeded before upstream send", status: 504)
        }
        let client = self.client
        let attempt = Task {
            try await Self.withDeadline(remaining) { try await client.send(body, snapshot: snapshot) }
        }
        upstreamTasks[id] = attempt
        defer { upstreamTasks[id] = nil }
        return try await attempt.value
    }

    func hasReadySource() async -> Bool {
        guard let sources = try? await store.sources(), let profiles = try? await store.profiles(),
            let keys = try? await store.sourceKeys()
        else { return false }
        return sources.contains { source in
            source.enabled && !source.archived && keys.contains { $0.sourceID == source.id && $0.revokedAt == nil }
                && profiles.contains { $0.id == source.profileID && $0.enabled }
        }
    }

    func releaseReservation(_ id: UUID) async {
        do { try await store.release(requestID: id) } catch { if !stopping { storageFault = true } }
    }

    func admissionError(_ error: Error) -> FalconError {
        if let fault = error as? FalconError, fault.code == "storage_full" {
            storageRejections = min(storageRejections + 1, 9_999)
            return fault
        }
        storageFault = true
        return FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507)
    }

    func predatesClear(_ instant: ContinuousClock.Instant) -> Bool { lastClearInstant.map { instant < $0 } ?? false }

    func admissionStatus(since instant: ContinuousClock.Instant, sourceID: UUID? = nil) -> FalconError? {
        if storageFault { return FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507) }
        if predatesClear(instant) {
            return FalconError("history_cleared", "Request arrived before history was cleared", status: 503)
        }
        if paused || stopping { return FalconError("falcon_paused", "Proxy is paused", status: 503) }
        if inFlight.values.reduce(0, +) >= 8 {
            return FalconError("falcon_busy", "Concurrent request limit", status: 429)
        }
        if let sourceID, inFlight[sourceID, default: 0] >= 2 {
            return FalconError("falcon_busy", "Source request limit", status: 429)
        }
        return nil
    }

    static func upstreamHeaders(_ response: JevHTTPResult) -> [String: String] {
        var headers = ["Content-Type": response.contentType ?? "application/json"]
        if let retryAfter = response.retryAfter { headers["Retry-After"] = retryAfter }
        if !(200...299).contains(response.status) { headers["X-Falcon-Error-Origin"] = "upstream" }
        return headers
    }

    static func errorReply(_ error: FalconError, id: UUID, instant: ContinuousClock.Instant) -> ProxyReply {
        let errorFields: [String: JSONValue] = [
            "origin": .string("falcon"), "code": .string(error.code), "message": .string(error.message),
            "request_id": .string(id.uuidString), "outcome_unknown": .bool(error.outcomeUnknown),
        ]
        let object: JSONValue = .object(["error": .object(errorFields)])
        return ProxyReply(
            status: error.status, body: (try? object.data()) ?? Data(), headers: ["Content-Type": "application/json"],
            requestID: id, error: error, receivedInstant: instant)
    }

    static func localError(_ error: Error, fallback: FalconError) -> FalconError { error as? FalconError ?? fallback }

    static func elapsed(since instant: ContinuousClock.Instant) -> Double {
        let components = instant.duration(to: ContinuousClock().now).components
        return max(0, Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000)
    }

    static func withDeadline<T: Sendable>(_ deadline: Duration, _ work: @escaping @Sendable () async throws -> T)
        async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw FalconError("upstream_timeout", "Upstream deadline exceeded", status: 504, outcomeUnknown: true)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func prepare(
        body: Data, defaultModel: String?, receivedInstant: ContinuousClock.Instant, summary: inout RequestSummary,
        detail: inout RequestDetail
    ) throws -> (JevRequest, Data) {
        guard body.count <= FalconLimits.requestBytes, (detail.receivedRequest?.count ?? 0) <= FalconLimits.requestBytes
        else {
            detail.receivedRequest = nil
            summary.metadata["body_complete"] = "false"
            throw FalconError("request_too_large", "Request body exceeded limit", status: 413)
        }
        summary.timing.bodyReceivedMS = elapsed(since: receivedInstant)
        let request = try JevRequest(JSONValue.decode(body), defaultModel: defaultModel)
        let effectiveBody = try request.value.data()
        guard effectiveBody.count <= FalconLimits.requestBytes else {
            detail.receivedRequest = nil
            summary.timing.bodyReceivedMS = nil
            summary.metadata["body_complete"] = "false"
            throw FalconError("request_too_large", "Effective request exceeded limit", status: 413)
        }
        summary.requestedModel = request.model
        summary.questionCount = request.questions.count
        summary.preview = request.value["state"]?.displayText.prefix(160).description ?? ""
        return (request, effectiveBody)
    }

    func recordRejected(
        _ error: FalconError, id: UUID, bodyBytes: Int, since instant: ContinuousClock.Instant,
        detail originalDetail: RequestDetail
    ) async -> ProxyReply {
        var detail = originalDetail
        var summary = detail.summary
        summary.status = .rejected
        summary.httpStatus = error.status
        summary.errorCode = error.code
        summary.errorMessage = error.message
        summary.timing.terminalMS = Self.elapsed(since: instant)
        detail.summary = summary
        do {
            try await store.reserve(
                requestID: id, requestBytes: min(bodyBytes, FalconLimits.requestBytes), questionCount: 0)
        } catch { return Self.errorReply(admissionError(error), id: id, instant: instant) }
        defer { Task { await self.releaseReservation(id) } }
        do { try await store.insert(detail) } catch {
            storageFault = true
            return Self.errorReply(
                FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507), id: id,
                instant: instant)
        }
        return Self.errorReply(error, id: id, instant: instant)
    }

    func submissionFailure(
        _ error: Error, reserved: Bool, bodyBytes: Int, since instant: ContinuousClock.Instant, detail: RequestDetail
    ) async -> ProxyReply {
        let id = detail.id
        if reserved {
            if !stopping { storageFault = true }
            let failure =
                stopping
                ? FalconError("interrupted", "Proxy stopped during request", status: 503, outcomeUnknown: true)
                : FalconError(
                    "falcon_audit_unavailable", "Audit storage unavailable", status: 507,
                    outcomeUnknown: detail.summary.status == .inFlight)
            return Self.errorReply(failure, id: id, instant: instant)
        }
        let mapped = Self.localError(error, fallback: FalconError("invalid_json", "Invalid JSON request", status: 400))
        if mapped.status == 400 || mapped.status == 413 || mapped.status == 422 {
            return await recordRejected(mapped, id: id, bodyBytes: bodyBytes, since: instant, detail: detail)
        }
        if mapped.code == "storage_full" {
            storageRejections = min(storageRejections + 1, 9_999)
        } else if mapped.status != 503 && mapped.status != 429 {
            storageFault = true
        }
        return Self.errorReply(mapped, id: id, instant: instant)
    }

    func upstreamFailure(
        _ error: Error, id: UUID, since instant: ContinuousClock.Instant, detail originalDetail: RequestDetail
    ) async throws -> ProxyReply {
        var detail = originalDetail
        var summary = detail.summary
        if let limit = error as? JevResponseLimitError {
            detail.upstreamResponse = limit.prefix
            summary.metadata["response_complete"] = "false"
        }
        let mapped =
            stopping
            ? FalconError("interrupted", "Proxy stopped during request", status: 503, outcomeUnknown: true)
            : error is JevResponseLimitError
                ? FalconError(
                    "upstream_response_too_large", "Upstream response exceeded limit", status: 502, outcomeUnknown: true
                )
                : Self.localError(
                    error,
                    fallback: FalconError(
                        "upstream_transport", "Upstream transport failed", status: 502, outcomeUnknown: true))
        if mapped.code == "upstream_timeout" && !mapped.outcomeUnknown { summary.timing.upstreamStartedMS = nil }
        summary.status =
            stopping
            ? .interrupted
            : error is JevResponseLimitError
                ? .invalidResponse : mapped.code == "upstream_timeout" ? .timedOut : .transportError
        summary.httpStatus = mapped.status
        summary.errorCode = mapped.code
        summary.errorMessage = mapped.message
        summary.timing.terminalMS = Self.elapsed(since: instant)
        detail.summary = summary
        try await store.update(detail)
        guard try await store.detail(id: id) != nil else { throw AuditLostError() }
        return Self.errorReply(mapped, id: id, instant: instant)
    }

    func complete(
        _ upstream: JevHTTPResult, request: JevRequest, id: UUID, since instant: ContinuousClock.Instant,
        detail originalDetail: RequestDetail
    ) async throws -> ProxyReply {
        var detail = originalDetail
        var summary = detail.summary
        summary.timing.responseReceivedMS = Self.elapsed(since: instant)
        detail.upstreamResponse = upstream.body
        summary.httpStatus = upstream.status
        if (200...299).contains(upstream.status) {
            do {
                let answer = try JevResponse(JSONValue.decode(upstream.body), request: request)
                summary.status = .succeeded
                summary.resolvedModel = answer.resolvedModel
                summary.inputTokens = answer.inputTokens
                summary.outputTokens = answer.outputTokens
            } catch {
                summary.status = .invalidResponse
                summary.httpStatus = 502
                summary.errorCode = "invalid_response"
                summary.errorMessage = "Invalid Jev response"
            }
        } else {
            summary.status = .upstreamError
            summary.errorCode = "upstream_http_\(upstream.status)"
            summary.errorMessage = "Upstream returned HTTP \(upstream.status)"
        }
        summary.timing.terminalMS = Self.elapsed(since: instant)
        detail.summary = summary
        try await store.update(detail)
        guard try await store.detail(id: id) != nil else { throw AuditLostError() }
        if summary.status == .succeeded || summary.status == .upstreamError {
            return ProxyReply(
                status: summary.httpStatus ?? 502, body: upstream.body, headers: Self.upstreamHeaders(upstream),
                requestID: id, receivedInstant: instant)
        }
        return Self.errorReply(
            FalconError("invalid_response", "Invalid Jev response", status: 502, outcomeUnknown: true), id: id,
            instant: instant)
    }

}

private struct AuditLostError: Error {}
