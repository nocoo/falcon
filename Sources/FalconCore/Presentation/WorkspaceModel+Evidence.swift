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
}
