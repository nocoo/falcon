import Foundation

extension DecisionService {
    public func listModels(token: String, receivedInstant: ContinuousClock.Instant = ContinuousClock().now) async
        -> ProxyReply
    {
        if let error = admissionStatus(since: receivedInstant) { return modelError(error) }
        let snapshot: ExecutionSnapshot
        do { snapshot = try await configuration.acquire(token: token) } catch {
            return modelError(
                Self.localError(error, fallback: FalconError("falcon_unavailable", "Source unavailable", status: 503)))
        }
        defer { Task { await configuration.release(snapshot) } }
        let sourceID = snapshot.identity.source.id
        if let error = admissionStatus(since: receivedInstant, sourceID: sourceID) { return modelError(error) }
        let id = UUID()
        inFlight[sourceID, default: 0] += 1
        pendingIDs.insert(id)
        defer { endFlight(sourceID: sourceID, id: id) }
        do {
            let upstream = try await sendUpstream(nil, snapshot: snapshot, id: id, since: receivedInstant)
            return ProxyReply(
                status: upstream.status, body: upstream.body, headers: Self.upstreamHeaders(upstream),
                error: upstream.relayError)
        } catch {
            let failure =
                error is JevResponseLimitError
                ? FalconError("upstream_response_too_large", "Upstream response exceeded limit", status: 502)
                : Self.localError(
                    error, fallback: FalconError("upstream_transport", "Upstream transport failed", status: 502))
            return modelError(failure)
        }
    }

    private func modelError(_ error: FalconError) -> ProxyReply { Self.errorReply(error, id: nil, instant: nil) }
}
