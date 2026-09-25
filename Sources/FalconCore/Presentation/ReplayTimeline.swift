import Foundation

public enum ReplayStage: String, Sendable, CaseIterable {
    case headers, body, upstream, response, terminal, delivery
    public var title: String {
        switch self {
        case .headers: "Request received"
        case .body: "Input received"
        case .upstream: "Sent to Jev"
        case .response: "Response received"
        case .terminal: "Processing complete"
        case .delivery: "Return written"
        }
    }
}

public struct ReplayEvent: Identifiable, Sendable, Equatable {
    public let requestID: UUID
    public let stage: ReplayStage
    public let date: Date
    public var id: String { "\(requestID):\(stage.rawValue)" }
}

public struct ReplayTimeline: Sendable {
    public private(set) var records: [RequestSummary]
    public private(set) var events: [ReplayEvent]
    private var recordIDs: Set<UUID>
    private static func events(for records: [RequestSummary]) -> [ReplayEvent] {
        records.flatMap { record in
            let timing = record.timing
            let offsets: [(ReplayStage, Double?)] = [
                (.headers, 0), (.body, timing.bodyReceivedMS), (.upstream, timing.upstreamStartedMS),
                (.response, timing.responseReceivedMS), (.terminal, timing.terminalMS),
                (.delivery, timing.deliveryFinishedMS),
            ]
            return offsets.compactMap { stage, offset -> ReplayEvent? in
                guard let offset, offset.isFinite, offset >= 0 else { return nil }
                return ReplayEvent(
                    requestID: record.id, stage: stage, date: record.receivedAt.addingTimeInterval(offset / 1000))
            }
        }.sorted { left, right in
            if left.date != right.date { return left.date < right.date }
            if left.requestID != right.requestID { return left.requestID.uuidString < right.requestID.uuidString }
            return (ReplayStage.allCases.firstIndex(of: left.stage) ?? 0)
                < (ReplayStage.allCases.firstIndex(of: right.stage) ?? 0)
        }
    }
    public var start: Date { events.first?.date ?? .distantPast }
    public var end: Date { events.last?.date ?? start }
    public var duration: TimeInterval { max(0.001, end.timeIntervalSince(start)) }

    public init(records: [RequestSummary], now: Date = Date()) throws {
        guard records.count <= 10_000 else {
            throw FalconError("replay_limit", "Narrow the range to 10,000 decisions or fewer.", status: 422)
        }
        self.records = records.filter { $0.expiresAt > now && $0.status.isTerminal }
        self.records = self.records.map { record in
            var light = record
            light.metadata = [:]
            light.reviewNote = ""
            light.errorMessage = nil
            return light
        }
        self.events = Self.events(for: self.records)
        self.recordIDs = Set(self.records.map(\.id))
    }

    public mutating func removeExpired(now: Date) {
        guard records.contains(where: { $0.expiresAt <= now }) else { return }
        records.removeAll { $0.expiresAt <= now }
        events = Self.events(for: records)
        recordIDs = Set(records.map(\.id))
    }

    public func reveals(_ stage: ReplayStage, record: RequestSummary, at cursor: Date, now: Date) -> Bool {
        guard record.expiresAt > now, recordIDs.contains(record.id) else { return false }
        let offset: Double?
        switch stage {
        case .headers: offset = 0
        case .body: offset = record.timing.bodyReceivedMS
        case .upstream: offset = record.timing.upstreamStartedMS
        case .response: offset = record.timing.responseReceivedMS
        case .terminal: offset = record.timing.terminalMS
        case .delivery: offset = record.timing.deliveryFinishedMS
        }
        guard let offset else { return false }
        return record.receivedAt.addingTimeInterval(offset / 1000) <= cursor
    }

    public func nextEvent(after date: Date) -> Date? { events.first { $0.date > date }?.date }
    public func previousEvent(before date: Date) -> Date? { events.last { $0.date < date }?.date }

    public func nextAfterIdle(at cursor: Date) -> Date? {
        let hasPending = records.contains { record in
            guard record.receivedAt <= cursor else { return false }
            guard let terminal = record.timing.terminalMS else { return true }
            let end = record.receivedAt.addingTimeInterval((record.timing.deliveryFinishedMS ?? terminal) / 1000)
            return end > cursor
        }
        guard !hasPending, let next = nextEvent(after: cursor), next.timeIntervalSince(cursor) > 2 else { return nil }
        return next
    }
}
