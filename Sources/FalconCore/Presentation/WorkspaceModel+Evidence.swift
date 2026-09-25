import Foundation

extension WorkspaceModel {
    public var hasEvidenceFilter: Bool {
        timeRange != nil || fingerprintFilter != nil || confidenceFilter != nil || noulFilter != nil
    }

    public func clearEvidenceFilters() {
        timeRange = nil
        fingerprintFilter = nil
        confidenceFilter = nil
        noulFilter = nil
    }

    public func inspectBucket(_ bucket: UsageBucket) {
        timeRange = DateInterval(start: bucket.date, duration: usage.bucketSeconds)
        page = .decisions
    }
    public var replayProgress: Double {
        guard let timeline else { return 0 }
        return min(1, max(0, playbackDate.timeIntervalSince(timeline.start) / timeline.duration))
    }
    public var inputsVisible: Bool { reveals(.body) }
    public var resultsVisible: Bool { reveals(.response) }
    public var terminalVisible: Bool { reveals(.terminal) }
    public var deliveryVisible: Bool { reveals(.delivery) }
    public var isSelecting: Bool { selectedID != nil && selectedID != detail?.id }
    public var visibleStatus: String {
        guard let detail else { return "No selection" }
        if timeline == nil || terminalVisible { return detail.summary.status.title }
        if resultsVisible { return "Response received" }
        if reveals(.upstream) { return "Waiting for Jev" }
        if inputsVisible { return "Preparing request" }
        return reveals(.headers) ? "Receiving input" : "Not yet received"
    }
    public var selectedEvents: [ReplayEvent] { timeline?.events.filter { $0.requestID == selectedID } ?? [] }

    private func reveals(_ stage: ReplayStage) -> Bool {
        guard isActive, let detail, detail.summary.isRetained(at: Date()) else { return false }
        guard let timeline else { return true }
        return timeline.reveals(stage, record: detail.summary, at: playbackDate, now: Date())
    }

}
