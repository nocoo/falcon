import Foundation

public enum DecisionServiceState: String, Sendable {
    case needsSetup = "needs_setup"
    case ready, paused
    case storageFault = "storage_fault"
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

    public init(
        status: Int, body: Data, headers: [String: String] = [:], requestID: UUID? = nil, error: FalconError? = nil,
        receivedInstant: ContinuousClock.Instant? = nil
    ) {
        self.status = status
        self.body = body
        self.headers = headers
        self.requestID = requestID
        self.error = error
        self.receivedInstant = receivedInstant
    }
}

public actor DecisionService {
    let store: DecisionStore
    private let configuration: ConfigurationManager
    let client: JevClient
    let deadline: Duration
    var paused = false
    var storageFault = false
    var stopping = false
    var storageRejections = 0
    var lastClearInstant: ContinuousClock.Instant?
    var inFlight: [UUID: Int] = [:]
    var pendingIDs: Set<UUID> = []
    var upstreamTasks: [UUID: Task<JevHTTPResult, Error>] = [:]

    public init(
        store: DecisionStore, configuration: ConfigurationManager, client: JevClient = .init(),
        deadline: Duration = .seconds(FalconLimits.timeout)
    ) {
        self.store = store
        self.configuration = configuration
        self.client = client
        self.deadline = deadline
    }

    public func pause() { paused = true }

    public func pauseAndDrain() async throws {
        paused = true
        while !pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
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
        do { try await store.clearHistory() } catch {
            storageFault = true
            throw error
        }
        if !wasPaused && !storageFault && !stopping { try await resume() }
    }

    public func shutdown(grace: Duration = .seconds(5)) async {
        paused = true
        stopping = true
        let deadline = ContinuousClock().now.advanced(by: grace)
        while !pendingIDs.isEmpty && ContinuousClock().now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        guard !pendingIDs.isEmpty else { return }
        for task in upstreamTasks.values { task.cancel() }
        do { try await store.recoverInterrupted() } catch { storageFault = true }
        for id in pendingIDs { try? await store.release(requestID: id) }
    }

    public func resume() async throws {
        guard !storageFault, !stopping else {
            throw FalconError(
                "falcon_audit_unavailable", "Proxy cannot resume after audit fault or shutdown", status: 507)
        }
        try await store.cleanup()
        paused = false
    }

    public func status() async -> DecisionServiceStatus {
        let state: DecisionServiceState
        if storageFault {
            state = .storageFault
        } else if paused {
            state = .paused
        } else if await hasReadySource() {
            state = .ready
        } else {
            state = .needsSetup
        }
        return DecisionServiceStatus(
            state: state, inFlight: inFlight.values.reduce(0, +), storageRejections: storageRejections)
    }

    public func rejectIncomplete(
        token: String, code: String, status: Int, metadata: [String: String] = [:], receivedAt: Date,
        receivedInstant: ContinuousClock.Instant
    ) async -> ProxyReply {
        let id = UUID()
        if let error = incompleteStatus(since: receivedInstant, requireRunning: false) {
            return Self.errorReply(error, id: id, instant: receivedInstant)
        }
        let snapshot: ExecutionSnapshot
        do { snapshot = try await configuration.acquire(token: token) } catch {
            return Self.errorReply(
                Self.localError(error, fallback: FalconError("falcon_unavailable", "Source unavailable", status: 503)),
                id: id, instant: receivedInstant)
        }
        defer { Task { await configuration.release(snapshot) } }
        if let error = incompleteStatus(since: receivedInstant, requireRunning: true) {
            return Self.errorReply(error, id: id, instant: receivedInstant)
        }
        pendingIDs.insert(id)
        defer { pendingIDs.remove(id) }
        var summary = RequestSummary(
            id: id, sourceID: snapshot.identity.source.id, keyID: snapshot.identity.keyID,
            sourceName: snapshot.identity.source.name, profileID: snapshot.profile.id,
            profileName: snapshot.profile.name, profileRevision: snapshot.profile.revision,
            baseURL: snapshot.profile.baseURL, receivedAt: receivedAt, status: .rejected,
            requestedModel: snapshot.profile.defaultModel)
        summary.metadata = metadata.merging(["body_complete": "false"]) { _, new in new }
        summary.httpStatus = status
        summary.errorCode = code
        summary.errorMessage = code
        summary.timing.terminalMS = Self.elapsed(since: receivedInstant)
        do { try await store.reserve(requestID: id, requestBytes: 0, questionCount: 0) } catch {
            return Self.errorReply(admissionError(error), id: id, instant: receivedInstant)
        }
        do { try await store.insert(RequestDetail(summary: summary)) } catch {
            try? await store.release(requestID: id)
            storageFault = true
            return Self.errorReply(
                FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507), id: id,
                instant: receivedInstant)
        }
        do { try await store.release(requestID: id) } catch {
            storageFault = true
            return Self.errorReply(
                FalconError("falcon_audit_unavailable", "Audit storage unavailable", status: 507), id: id,
                instant: receivedInstant)
        }
        return Self.errorReply(FalconError(code, code, status: status), id: id, instant: receivedInstant)
    }

    public func submit(
        token: String, body: Data, receivedRequest: Data? = nil, transport: RequestTransport = .http,
        metadata: [String: String] = [:], receivedAt: Date = Date(),
        receivedInstant: ContinuousClock.Instant = ContinuousClock().now
    ) async -> ProxyReply {
        let id = UUID()
        let makeError: (FalconError) -> ProxyReply = { error in Self.errorReply(error, id: id, instant: receivedInstant)
        }
        if let error = admissionStatus(since: receivedInstant) { return makeError(error) }

        let snapshot: ExecutionSnapshot
        do { snapshot = try await configuration.acquire(token: token) } catch {
            return makeError(
                Self.localError(error, fallback: FalconError("falcon_unavailable", "Source unavailable", status: 503)))
        }
        defer { Task { await configuration.release(snapshot) } }
        let sourceID = snapshot.identity.source.id
        if let error = admissionStatus(since: receivedInstant, sourceID: sourceID) { return makeError(error) }
        inFlight[sourceID, default: 0] += 1
        pendingIDs.insert(id)
        defer { endFlight(sourceID: sourceID, id: id) }

        var summary = RequestSummary(
            id: id, sourceID: sourceID, keyID: snapshot.identity.keyID, sourceName: snapshot.identity.source.name,
            profileID: snapshot.profile.id, profileName: snapshot.profile.name,
            profileRevision: snapshot.profile.revision, baseURL: snapshot.profile.baseURL, transport: transport,
            receivedAt: receivedAt, requestedModel: snapshot.profile.defaultModel)
        summary.metadata = metadata
        var detail = RequestDetail(summary: summary, receivedRequest: receivedRequest ?? body)
        var reserved = false
        defer { if reserved { Task { await self.releaseReservation(id) } } }
        do {
            let (request, effectiveBody) = try Self.prepare(
                body: body, defaultModel: transport == .mcp ? snapshot.profile.defaultModel : nil,
                receivedInstant: receivedInstant, summary: &summary, detail: &detail)
            detail.summary = summary
            detail.effectiveRequest = effectiveBody
            try await store.reserve(
                requestID: id, requestBytes: max(receivedRequest?.count ?? body.count, effectiveBody.count),
                questionCount: request.questions.count)
            reserved = true
            try await store.insert(detail)
            summary.status = .inFlight
            summary.timing.upstreamStartedMS = Self.elapsed(since: receivedInstant)
            detail.summary = summary
            try await store.update(detail)
            let upstream: JevHTTPResult
            do {
                upstream = try await sendUpstream(effectiveBody, snapshot: snapshot, id: id, since: receivedInstant)
            } catch { return try await upstreamFailure(error, id: id, since: receivedInstant, detail: detail) }
            return try await complete(upstream, request: request, id: id, since: receivedInstant, detail: detail)
        } catch {
            detail.summary = summary
            return await submissionFailure(
                error, reserved: reserved, bodyBytes: body.count, since: receivedInstant, detail: detail)
        }
    }

    public func deliveryWritten(id: UUID, since instant: ContinuousClock.Instant) async {
        guard !stopping else { return }
        do {
            try await store.updateDelivery(id: id, state: .written, finishedMS: Self.elapsed(since: instant))
        } catch let error as FalconError where error.code == "request_missing" { return } catch {
            if !stopping { storageFault = true }
        }
    }

    public func deliveryFailed(id: UUID) async {
        guard !stopping else { return }
        do { try await store.updateDelivery(id: id, state: .failed, finishedMS: nil) } catch {
            if (error as? FalconError)?.code == "request_missing" { return }
            if !stopping { storageFault = true }
        }
    }

}
