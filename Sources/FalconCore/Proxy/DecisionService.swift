import Foundation

public enum DecisionServiceState: String, Sendable {
    case needsSetup = "needs_setup", ready, paused, storageFault = "storage_fault"
}

public struct DecisionServiceStatus: Sendable {
    public let state: DecisionServiceState
    public let inFlight: Int
    public let storageRejections: Int
}

public struct ProxyReply: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]
    public let requestID: UUID?
    public let error: FalconError?
    public let receivedInstant: ContinuousClock.Instant?

    public init(status: Int, body: Data, headers: [String: String] = [:], requestID: UUID? = nil,
                error: FalconError? = nil, receivedInstant: ContinuousClock.Instant? = nil) {
        self.status = status
        self.body = body
        self.headers = headers
        self.requestID = requestID
        self.error = error
        self.receivedInstant = receivedInstant
    }
}

public actor DecisionService {
    private let store: DecisionStore
    private let configuration: ConfigurationManager
    private let client: JevClient
    private let deadline: Duration
    private var paused = false
    private var storageFault = false
    private var stopping = false
    private var storageRejections = 0
    private var lastClearInstant: ContinuousClock.Instant?
    private var inFlight: [UUID: Int] = [:]
    private var pendingIDs: Set<UUID> = []
    private var upstreamTasks: [UUID: Task<JevHTTPResult, Error>] = [:]

    public init(store: DecisionStore, configuration: ConfigurationManager, client: JevClient = .init(),
                deadline: Duration = .seconds(FalconLimits.timeout)) {
        self.store = store
        self.configuration = configuration
        self.client = client
        self.deadline = deadline
    }

    public func pause() { paused = true }

    public func pauseAndDrain() async throws {
        paused = true
        while !pendingIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    public func clearHistory() async throws {
        let wasPaused = paused
        paused = true
        lastClearInstant = ContinuousClock().now
        let deadline = ContinuousClock().now.advanced(by: .seconds(35))
        while !pendingIDs.isEmpty {
            guard ContinuousClock().now < deadline else {
                throw FalconError("requests_still_active", "Requests are still active", status: 503)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        do { try await store.clearHistory() }
        catch {
            storageFault = true
            throw error
        }
        if !wasPaused && !storageFault && !stopping { try await resume() }
    }

    public func shutdown(grace: Duration = .seconds(5)) async {
        paused = true
        stopping = true
        let deadline = ContinuousClock().now.advanced(by: grace)
        while !pendingIDs.isEmpty && ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard !pendingIDs.isEmpty else { return }
        for task in upstreamTasks.values { task.cancel() }
        do { try await store.recoverInterrupted() }
        catch { storageFault = true }
        for id in pendingIDs { try? await store.release(requestID: id) }
    }

    public func resume() async throws {
        guard !storageFault, !stopping else {
            throw FalconError("falcon_audit_unavailable", "Proxy cannot resume after audit fault or shutdown", status: 507)
        }
        try await store.cleanup()
        paused = false
    }

    public func status() async -> DecisionServiceStatus {
        let state: DecisionServiceState
        if storageFault { state = .storageFault }
        else if paused { state = .paused }
        else if let sources = try? await store.sources(), let profiles = try? await store.profiles(),
                let keys = try? await store.sourceKeys(),
                sources.contains(where: { source in
                    source.enabled && !source.archived && keys.contains(where: { $0.sourceID == source.id && $0.revokedAt == nil })
                        && profiles.contains(where: { $0.id == source.profileID && $0.enabled })
                }) { state = .ready }
        else { state = .needsSetup }
        return DecisionServiceStatus(state: state, inFlight: inFlight.values.reduce(0, +),
                                     storageRejections: storageRejections)
    }

    public func rejectIncomplete(token: String, code: String, status: Int, metadata: [String: String] = [:],
                                 receivedAt: Date, receivedInstant: ContinuousClock.Instant) async -> ProxyReply {
        let id = UUID()
        guard !storageFault else {
            return Self.errorReply(FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507), id: id, instant: receivedInstant)
        }
        guard !predatesClear(receivedInstant) else {
            return Self.errorReply(FalconError("history_cleared", "Request arrived before history was cleared", status: 503), id: id, instant: receivedInstant)
        }
        let snapshot: ExecutionSnapshot
        do { snapshot = try await configuration.acquire(token: token) }
        catch {
            return Self.errorReply(Self.localError(error, fallback: FalconError("falcon_unavailable", "Source unavailable", status: 503)),
                                   id: id, instant: receivedInstant)
        }
        defer { Task { await configuration.release(snapshot) } }
        guard !storageFault else {
            return Self.errorReply(FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507), id: id, instant: receivedInstant)
        }
        guard !predatesClear(receivedInstant) else {
            return Self.errorReply(FalconError("history_cleared", "Request arrived before history was cleared", status: 503), id: id, instant: receivedInstant)
        }
        guard !paused, !stopping else {
            return Self.errorReply(FalconError("falcon_paused", "Proxy is paused", status: 503), id: id, instant: receivedInstant)
        }
        pendingIDs.insert(id)
        defer { pendingIDs.remove(id) }
        var summary = RequestSummary(id: id, sourceID: snapshot.identity.source.id, keyID: snapshot.identity.keyID,
                                     sourceName: snapshot.identity.source.name, profileID: snapshot.profile.id,
                                     profileName: snapshot.profile.name, profileRevision: snapshot.profile.revision,
                                     baseURL: snapshot.profile.baseURL, receivedAt: receivedAt,
                                     status: .rejected, requestedModel: snapshot.profile.defaultModel)
        summary.metadata = metadata.merging(["body_complete": "false"]) { _, new in new }
        summary.httpStatus = status
        summary.errorCode = code
        summary.errorMessage = code
        summary.timing.terminalMS = Self.elapsed(since: receivedInstant)
        do { try await store.reserve(requestID: id, requestBytes: 0, questionCount: 0) }
        catch { return Self.errorReply(admissionError(error), id: id, instant: receivedInstant) }
        do { try await store.insert(RequestDetail(summary: summary)) }
        catch {
            try? await store.release(requestID: id)
            storageFault = true
            return Self.errorReply(FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507), id: id, instant: receivedInstant)
        }
        do { try await store.release(requestID: id) }
        catch {
            storageFault = true
            return Self.errorReply(FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507), id: id, instant: receivedInstant)
        }
        return Self.errorReply(FalconError(code, code, status: status), id: id, instant: receivedInstant)
    }

    public func submit(token: String, body: Data, receivedRequest: Data? = nil,
                       transport: RequestTransport = .http, metadata: [String: String] = [:],
                       receivedAt: Date = Date(), receivedInstant: ContinuousClock.Instant = ContinuousClock().now) async -> ProxyReply {
        let id = UUID()
        let makeError: (FalconError) -> ProxyReply = { error in
            Self.errorReply(error, id: id, instant: receivedInstant)
        }
        guard !storageFault else { return makeError(FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507)) }
        guard !predatesClear(receivedInstant) else { return makeError(FalconError("history_cleared", "Request arrived before history was cleared", status: 503)) }
        guard !paused else { return makeError(FalconError("falcon_paused", "Proxy is paused", status: 503)) }
        guard inFlight.values.reduce(0, +) < 8 else { return makeError(FalconError("falcon_busy", "Concurrent request limit", status: 429)) }

        let snapshot: ExecutionSnapshot
        do { snapshot = try await configuration.acquire(token: token) }
        catch { return makeError(Self.localError(error, fallback: FalconError("falcon_unavailable", "Source unavailable", status: 503))) }
        defer { Task { await configuration.release(snapshot) } }
        guard !storageFault else {
            return makeError(FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507))
        }
        guard !predatesClear(receivedInstant) else {
            return makeError(FalconError("history_cleared", "Request arrived before history was cleared", status: 503))
        }
        guard !paused, !stopping else {
            return makeError(FalconError("falcon_paused", "Proxy is paused", status: 503))
        }
        let sourceID = snapshot.identity.source.id
        guard inFlight.values.reduce(0, +) < 8 else { return makeError(FalconError("falcon_busy", "Concurrent request limit", status: 429)) }
        guard inFlight[sourceID, default: 0] < 2 else {
            return makeError(FalconError("falcon_busy", "Source request limit", status: 429))
        }
        inFlight[sourceID, default: 0] += 1
        pendingIDs.insert(id)
        defer {
            inFlight[sourceID, default: 1] -= 1
            if inFlight[sourceID] == 0 { inFlight[sourceID] = nil }
            pendingIDs.remove(id)
        }

        var summary = RequestSummary(id: id, sourceID: sourceID, keyID: snapshot.identity.keyID,
                                     sourceName: snapshot.identity.source.name, profileID: snapshot.profile.id,
                                     profileName: snapshot.profile.name, profileRevision: snapshot.profile.revision,
                                     baseURL: snapshot.profile.baseURL, transport: transport,
                                     receivedAt: receivedAt, requestedModel: snapshot.profile.defaultModel)
        summary.metadata = metadata
        var detail = RequestDetail(summary: summary, receivedRequest: receivedRequest ?? body)
        var reserved = false
        defer {
            if reserved { Task { await self.releaseReservation(id) } }
        }
        do {
            guard body.count <= FalconLimits.requestBytes,
                  (receivedRequest?.count ?? 0) <= FalconLimits.requestBytes else {
                detail.receivedRequest = nil
                summary.metadata["body_complete"] = "false"
                throw FalconError("request_too_large", "Request body exceeded limit", status: 413)
            }
            summary.timing.bodyReceivedMS = Self.elapsed(since: receivedInstant)
            let value = try JSONValue.decode(body)
            let request = try JevRequest(value, defaultModel: transport == .mcp ? snapshot.profile.defaultModel : nil)
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
            detail.summary = summary
            detail.effectiveRequest = effectiveBody
            try await store.reserve(requestID: id,
                                    requestBytes: max(receivedRequest?.count ?? body.count, effectiveBody.count),
                                    questionCount: request.questions.count)
            reserved = true
            try await store.insert(detail)
            summary.status = .inFlight
            summary.timing.upstreamStartedMS = Self.elapsed(since: receivedInstant)
            detail.summary = summary
            try await store.update(detail)
            let upstream: JevHTTPResult
            do {
                let remaining = self.deadline - receivedInstant.duration(to: ContinuousClock().now)
                guard remaining > .zero else {
                    throw FalconError("upstream_timeout", "Request deadline exceeded before upstream send", status: 504)
                }
                let client = self.client
                let attempt = Task { try await Self.withDeadline(remaining) { try await client.send(effectiveBody, snapshot: snapshot) } }
                upstreamTasks[id] = attempt
                defer { upstreamTasks[id] = nil }
                upstream = try await attempt.value
            } catch {
                if let limit = error as? JevResponseLimitError {
                    detail.upstreamResponse = limit.prefix
                    summary.metadata["response_complete"] = "false"
                }
                let mapped = stopping ? FalconError("interrupted", "Proxy stopped during request", status: 503, outcomeUnknown: true)
                    : error is JevResponseLimitError ? FalconError("upstream_response_too_large", "Upstream response exceeded limit", status: 502, outcomeUnknown: true)
                    : Self.localError(error, fallback: FalconError("upstream_transport", "Upstream transport failed", status: 502, outcomeUnknown: true))
                if mapped.code == "upstream_timeout" && !mapped.outcomeUnknown { summary.timing.upstreamStartedMS = nil }
                summary.status = stopping ? .interrupted : error is JevResponseLimitError ? .invalidResponse
                    : mapped.code == "upstream_timeout" ? .timedOut : .transportError
                summary.httpStatus = mapped.status
                summary.errorCode = mapped.code
                summary.errorMessage = mapped.message
                summary.timing.terminalMS = Self.elapsed(since: receivedInstant)
                detail.summary = summary
                try await store.update(detail)
                guard try await store.detail(id: id) != nil else { throw AuditLostError() }
                return makeError(mapped)
            }
            summary.timing.responseReceivedMS = Self.elapsed(since: receivedInstant)
            detail.upstreamResponse = upstream.body
            summary.httpStatus = upstream.status
            var answer: JevResponse?
            if (200...299).contains(upstream.status) {
                do { answer = try JevResponse(JSONValue.decode(upstream.body), request: request) }
                catch {
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
            if let answer {
                summary.status = .succeeded
                summary.resolvedModel = answer.resolvedModel
                summary.inputTokens = answer.inputTokens
                summary.outputTokens = answer.outputTokens
            }
            summary.timing.terminalMS = Self.elapsed(since: receivedInstant)
            detail.summary = summary
            try await store.update(detail)
            guard try await store.detail(id: id) != nil else { throw AuditLostError() }
            let status = summary.httpStatus ?? 502
            let headers = Self.upstreamHeaders(upstream)
            if summary.status == .succeeded || summary.status == .upstreamError {
                return ProxyReply(status: status, body: upstream.body, headers: headers,
                                  requestID: id, receivedInstant: receivedInstant)
            }
            return makeError(FalconError("invalid_response", "Invalid Jev response", status: 502, outcomeUnknown: true))
        } catch {
            if reserved {
                if !stopping { storageFault = true }
                if stopping { return makeError(FalconError("interrupted", "Proxy stopped during request", status: 503, outcomeUnknown: true)) }
                return makeError(FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507,
                                             outcomeUnknown: summary.status == .inFlight))
            }
            let mapped = Self.localError(error, fallback: FalconError("invalid_json", "Invalid JSON request", status: 400))
            if mapped.status == 400 || mapped.status == 413 || mapped.status == 422 {
                summary.status = .rejected
                summary.httpStatus = mapped.status
                summary.errorCode = mapped.code
                summary.errorMessage = mapped.message
                summary.timing.terminalMS = Self.elapsed(since: receivedInstant)
                detail.summary = summary
                do {
                    try await store.reserve(requestID: id, requestBytes: min(body.count, FalconLimits.requestBytes), questionCount: 0)
                    reserved = true
                    try await store.insert(detail)
                } catch {
                    if !reserved { return makeError(admissionError(error)) }
                    storageFault = true
                    return makeError(FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507))
                }
            } else if mapped.code == "storage_full" {
                storageRejections = min(storageRejections + 1, 9_999)
            } else if mapped.status != 503 && mapped.status != 429 { storageFault = true }
            return makeError(mapped)
        }
    }

    public func deliveryWritten(id: UUID, since instant: ContinuousClock.Instant) async {
        guard !stopping else { return }
        do { try await store.updateDelivery(id: id, state: .written, finishedMS: Self.elapsed(since: instant)) }
        catch let error as FalconError where error.code == "request_missing" { return }
        catch { if !stopping { storageFault = true } }
    }

    public func deliveryFailed(id: UUID) async {
        guard !stopping else { return }
        do { try await store.updateDelivery(id: id, state: .failed, finishedMS: nil) }
        catch let error as FalconError where error.code == "request_missing" { return }
        catch { if !stopping { storageFault = true } }
    }

    private func releaseReservation(_ id: UUID) async {
        do { try await store.release(requestID: id) }
        catch { if !stopping { storageFault = true } }
    }

    private func admissionError(_ error: Error) -> FalconError {
        if let fault = error as? FalconError, fault.code == "storage_full" {
            storageRejections = min(storageRejections + 1, 9_999)
            return fault
        }
        storageFault = true
        return FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507)
    }

    private func predatesClear(_ instant: ContinuousClock.Instant) -> Bool {
        lastClearInstant.map { instant < $0 } ?? false
    }

    private static func upstreamHeaders(_ response: JevHTTPResult) -> [String: String] {
        var headers = ["Content-Type": response.contentType ?? "application/json"]
        if let retryAfter = response.retryAfter { headers["Retry-After"] = retryAfter }
        if !(200...299).contains(response.status) { headers["X-Falcon-Error-Origin"] = "upstream" }
        return headers
    }

    private static func errorReply(_ error: FalconError, id: UUID, instant: ContinuousClock.Instant) -> ProxyReply {
        let object: JSONValue = .object(["error": .object([
            "origin": .string("falcon"), "code": .string(error.code), "message": .string(error.message),
            "request_id": .string(id.uuidString), "outcome_unknown": .bool(error.outcomeUnknown)
        ])])
        return ProxyReply(status: error.status, body: (try? object.data()) ?? Data(),
                          headers: ["Content-Type": "application/json"], requestID: id,
                          error: error, receivedInstant: instant)
    }

    private static func localError(_ error: Error, fallback: FalconError) -> FalconError {
        error as? FalconError ?? fallback
    }

    private static func elapsed(since instant: ContinuousClock.Instant) -> Double {
        let components = instant.duration(to: ContinuousClock().now).components
        return max(0, Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000)
    }

    private static func withDeadline<T: Sendable>(_ deadline: Duration,
                                                   _ work: @escaping @Sendable () async throws -> T) async throws -> T {
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
}

private struct AuditLostError: Error {}
