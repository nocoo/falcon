import Foundation
import Observation

public enum WorkspacePage: String, CaseIterable, Sendable {
    case decisions = "Decisions"
    case usage = "Usage"
    case sources = "Sources"
    case connections = "Connections"
    case settings = "Settings"
    public var symbol: String {
        switch self {
        case .decisions: "rectangle.split.2x1"
        case .usage: "chart.xyaxis.line"
        case .sources: "point.3.connected.trianglepath.dotted"
        case .connections: "arrow.up.right.square"
        case .settings: "slider.horizontal.3"
        }
    }
}

@MainActor @Observable public final class WorkspaceModel {
    public var page: WorkspacePage = .decisions
    public var focusReview = false
    public var search = ""
    public var sourceFilters: Set<UUID> = []
    public var timeRange: DateInterval?
    public var fingerprintFilter: String?
    public var confidenceFilter: Int?
    public var noulFilter: Int?
    public var statusFilter: RequestStatus?
    public var reviewFilter: ReviewState?
    public var starredOnly = false
    public var hours = 168
    public var usageShowsTokens = false
    public var usageShowsReturn = false
    public var usageScrollID: String?
    public var selectedID: UUID?
    public private(set) var requests: [RequestSummary] = []
    public private(set) var previews: [UUID: RequestPreview] = [:]
    public private(set) var detail: RequestDetail?
    public private(set) var presentation: DecisionPresentation?
    public private(set) var profiles: [UpstreamProfile] = []
    public private(set) var sources: [AgentSource] = []
    public private(set) var keys: [SourceKey] = []
    public private(set) var usage = UsageSnapshot()
    public private(set) var storageBytes: Int64 = 0
    public private(set) var isLoading = false
    public private(set) var hasMore = false
    public private(set) var newArrivalCount = 0
    public private(set) var isActive = true
    public var errorMessage: String?
    public var note = ""
    public var reviewState: ReviewState = .unreviewed
    public private(set) var noteIsDirty = false
    public private(set) var isUpdatingStar = false
    public private(set) var isTriaging = false
    public private(set) var triageMessage: String?
    public private(set) var timeline: ReplayTimeline?
    public private(set) var playbackDate = Date()
    public private(set) var isPlaying = false
    public var playbackSpeed = 1.0
    public var skipIdle = false
    public var followArrivals = false
    public private(set) var skippedSeconds: Double = 0
    public let isPreview: Bool
    @ObservationIgnored public let store: DecisionStore
    @ObservationIgnored public let configuration: ConfigurationManager?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRevision = 0
    @ObservationIgnored private var filterAnchor = Date()
    @ObservationIgnored private var refreshRevision = 0
    @ObservationIgnored private var paginationCursor: RequestCursor?

    public init(store: DecisionStore, configuration: ConfigurationManager? = nil, preview: Bool = false) {
        self.store = store
        self.configuration = configuration
        self.isPreview = preview
    }

    public var filter: DecisionFilter {
        DecisionFilter(
            since: starredOnly ? nil : timeRange?.start ?? filterAnchor.addingTimeInterval(-Double(hours) * 3600),
            until: starredOnly ? nil : timeRange?.end ?? filterAnchor, sourceIDs: sourceFilters, status: statusFilter,
            reviewState: reviewFilter, search: search, questionFingerprint: fingerprintFilter,
            confidenceBand: confidenceFilter, noulBand: noulFilter, starredOnly: starredOnly)
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

    public func observeChanges() async {
        do {
            for try await _ in await store.changes() {
                guard !Task.isCancelled else { return }
                await refresh()
            }
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    public func refresh(reset: Bool = false) async {
        validateExpiry()
        guard isActive else { return }
        refreshRevision += 1
        let revision = refreshRevision
        filterAnchor = Date()
        if reset {
            stopReplay()
            isLoading = true
        }
        defer { if revision == refreshRevision { isLoading = false } }
        do {
            let query = filter
            let fetched = try await store.requests(filter: query)
            let updatedPreviews = try await store.requestPreviews(
                ids: fetched.filter {
                    previews[$0.id]?.status != $0.status || previews[$0.id]?.starredAt != $0.starredAt
                }.map(\.id))
            let currentProfiles = try await store.profiles()
            let currentSources = try await store.sources()
            let currentKeys = try await store.sourceKeys()
            let bytes = try await store.storageBytes()
            let usageQuery =
                page == .sources
                ? DecisionFilter(since: filterAnchor.addingTimeInterval(-86_400), until: filterAnchor) : query
            let snapshot = page == .usage || page == .sources || reset ? try await store.usage(filter: usageQuery) : nil
            guard revision == refreshRevision, query == filter, isActive else { return }
            profiles = currentProfiles
            sources = currentSources
            keys = currentKeys
            storageBytes = bytes
            if let snapshot { usage = snapshot }
            mergeRequests(fetched, query: query, reset: reset)
            previews.merge(updatedPreviews) { _, new in new }
            let visibleIDs = Set(requests.map(\.id))
            previews = previews.filter { visibleIDs.contains($0.key) }
            await refreshSelection(fetched: fetched, reset: reset)
        } catch { if revision == refreshRevision { errorMessage = error.localizedDescription } }
    }

    private func refreshSelection(fetched: [RequestSummary], reset: Bool) async {
        guard !isTriaging, !isUpdatingStar else { return }
        if selectedID == nil, let first = requests.first {
            await select(first.id)
        } else if reset, let selectedID, !requests.contains(where: { $0.id == selectedID }) {
            await select(requests.first?.id)
        } else if let detail, !isSelecting,
            !detail.summary.status.isTerminal || (detail.summary.isStarred && detail.summary.expiresAt <= Date())
                || fetched.first(where: { $0.id == detail.id }).map({ $0 != detail.summary }) == true
        {
            await loadDetail(detail.id)
        }
    }

    private func mergeRequests(_ fetched: [RequestSummary], query: DecisionFilter, reset: Bool) {
        let loadedIDs = Set(requests.map(\.id))
        let arrivals = fetched.filter {
            !loadedIDs.contains($0.id) && $0.receivedAt >= (requests.first?.receivedAt ?? .distantFuture)
        }
        newArrivalCount = reset ? 0 : min(100, newArrivalCount + arrivals.count)
        if reset || fetched.count < 100 || loadedIDs.isEmpty {
            requests = fetched
            hasMore = fetched.count == 100
            paginationCursor = fetched.last.map { RequestCursor(receivedAt: $0.receivedAt, id: $0.id) }
        } else {
            let newIDs = Set(fetched.map(\.id))
            if loadedIDs.isDisjoint(with: newIDs) {
                paginationCursor = fetched.last.map { RequestCursor(receivedAt: $0.receivedAt, id: $0.id) }
                hasMore = true
            }
            requests =
                fetched
                + requests.filter {
                    !newIDs.contains($0.id) && $0.isRetained(at: Date()) && (!query.starredOnly || $0.isStarred)
                        && $0.receivedAt >= (query.since ?? .distantPast)
                }
        }
    }

    public func loadMore() async {
        guard let cursor = paginationCursor, hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let query = filter
            let rows = try await store.requests(filter: query, before: cursor)
            let updatedPreviews = try await store.requestPreviews(ids: rows.map(\.id))
            guard query == filter else { return }
            previews.merge(updatedPreviews) { _, new in new }
            let ids = Set(requests.map(\.id))
            requests += rows.filter { !ids.contains($0.id) }
            requests.sort {
                $0.receivedAt == $1.receivedAt ? $0.id.uuidString > $1.id.uuidString : $0.receivedAt > $1.receivedAt
            }
            paginationCursor = rows.last.map { RequestCursor(receivedAt: $0.receivedAt, id: $0.id) }
            hasMore = rows.count == 100
        } catch { errorMessage = error.localizedDescription }
    }

    public func showLatest() async {
        guard !isTriaging else { return }
        if noteIsDirty {
            await saveReview()
            if noteIsDirty { return }
        }
        await refresh(reset: true)
        await select(requests.first?.id)
    }

    public func selectAdjacent(forward: Bool) async {
        guard !isTriaging else { return }
        guard let index = requests.firstIndex(where: { $0.id == selectedID }) else { return }
        let next = index + (forward ? 1 : -1)
        if next == requests.count, hasMore { await loadMore() }
        guard requests.indices.contains(next) else { return }
        await select(requests[next].id)
    }

    public func select(_ id: UUID?) async {
        guard !isTriaging else { return }
        if noteIsDirty {
            await saveReview()
            if noteIsDirty { return }
        }
        pauseReplay()
        followArrivals = false
        beginSelection(id)
        if let id { await loadDetail(id) }
    }

    func beginSelection(_ id: UUID?) {
        if id != selectedID { triageMessage = nil }
        selectedID = id
        selectionRevision += 1
        if id == nil {
            detail = nil
            presentation = nil
            note = ""
            reviewState = .unreviewed
            noteIsDirty = false
        }
    }

    private func loadDetail(_ id: UUID) async {
        guard !((isTriaging || isUpdatingStar) && detail?.id == id) else { return }
        let revision = selectionRevision
        do {
            let loaded = try await store.detail(id: id)
            guard revision == selectionRevision, selectedID == id, isActive,
                !((isTriaging || isUpdatingStar) && detail?.id == id)
            else { return }
            guard let loaded else {
                if detail?.id == id {
                    beginSelection(nil)
                    pauseReplay()
                } else {
                    selectedID = detail?.id
                    validateExpiry()
                }
                errorMessage = "This decision is no longer available."
                return
            }
            let parsed = await Task.detached { DecisionPresentation(detail: loaded) }.value
            let preview =
                previews[id]?.status == loaded.summary.status && previews[id]?.starredAt == loaded.summary.starredAt
                ? previews[id] : try await store.requestPreviews(ids: [id])[id]
            guard revision == selectionRevision, selectedID == id, isActive,
                !((isTriaging || isUpdatingStar) && detail?.id == id)
            else { return }
            if !noteIsDirty || detail?.id != id {
                note = loaded.summary.reviewNote
                reviewState = loaded.summary.reviewState
                noteIsDirty = false
            }
            detail = loaded
            presentation = parsed
            previews[id] = preview
            if let index = requests.firstIndex(where: { $0.id == id }),
                !requests[index].status.isTerminal || loaded.summary.status.isTerminal
            {
                requests[index] = loaded.summary
            }
            validateExpiry()
        } catch {
            guard revision == selectionRevision, selectedID == id, !((isTriaging || isUpdatingStar) && detail?.id == id)
            else { return }
            selectedID = detail?.id
            errorMessage = error.localizedDescription
            pauseReplay()
        }
    }

    public func editNote(_ value: String) {
        guard !isSelecting else { return }
        note = value
        noteIsDirty = true
    }
    public func editReview(_ value: ReviewState) {
        guard !isSelecting else { return }
        reviewState = value
        noteIsDirty = true
    }
    public func saveReview() async {
        guard let id = detail?.id, isActive, !isSelecting, !isTriaging else { return }
        do {
            let savedNote = note
            let savedState = reviewState
            try await store.saveReview(id: id, state: savedState, note: savedNote)
            guard detail?.id == id, note == savedNote, reviewState == savedState else { return }
            noteIsDirty = false
            await loadDetail(id)
        } catch { errorMessage = error.localizedDescription }
    }

    public func toggleStar(id: UUID) async {
        guard isActive, !isSelecting, !isUpdatingStar, !isTriaging else { return }
        isUpdatingStar = true
        defer {
            isUpdatingStar = false
            validateExpiry()
        }
        do {
            guard let current = try await store.detail(id: id) else { return }
            if current.summary.isStarred && current.summary.expiresAt <= Date() && detail?.id == id && noteIsDirty {
                await saveReview()
                guard !noteIsDirty else { return }
            }
            try await store.setStarred(id: id, starred: !current.summary.isStarred)
            let updated = try await store.detail(id: id)
            try await applyStarUpdate(id: id, updated: updated)
        } catch { errorMessage = error.localizedDescription }
    }

    private func applyStarUpdate(id: UUID, updated: RequestDetail?) async throws {
        timeline?.updateStar(id: id, starredAt: updated?.summary.starredAt)
        if timeline?.records.isEmpty == true { stopReplay() }
        guard let updated else {
            requests.removeAll { $0.id == id }
            previews[id] = nil
            if selectedID == id { beginSelection(nil) }
            return
        }
        if let index = requests.firstIndex(where: { $0.id == id }) { requests[index] = updated.summary }
        if detail?.id == id { detail?.summary = updated.summary }
        previews.merge(try await store.requestPreviews(ids: [id])) { _, new in new }
        if starredOnly && !updated.summary.isStarred {
            requests.removeAll { $0.id == id }
            if selectedID == id && !noteIsDirty { await select(requests.first?.id) }
        }
    }

    public func triage() async {
        guard isActive, !isSelecting, !isTriaging, !isUpdatingStar, let current = detail, selectedID == current.id
        else { return }
        isTriaging = true
        defer { isTriaging = false }
        let id = current.id
        let revision = selectionRevision
        let savedNote = note
        let previousState = reviewState
        triageMessage = nil
        do {
            try await store.saveReview(id: id, state: .reviewed, note: savedNote)
            guard selectionRevision == revision, selectedID == id, note == savedNote, reviewState == previousState
            else { return }
            applyTriageReview(id: id, note: savedNote)
            var query = filter
            guard query.reviewState == nil || query.reviewState == .unreviewed else {
                triageMessage = "No unreviewed decisions match the current filters."
                return
            }
            query.reviewState = .unreviewed
            let selectedHours = hours
            let selectedRange = timeRange
            let cursor = RequestCursor(receivedAt: current.summary.receivedAt, id: id)
            let next = try await store.requests(filter: query, before: cursor, limit: 1).first
            var currentFilter = filter
            currentFilter.reviewState = .unreviewed
            currentFilter.since = query.since
            currentFilter.until = query.until
            guard selectionRevision == revision, selectedID == id, !noteIsDirty, isActive, query == currentFilter,
                hours == selectedHours, timeRange == selectedRange
            else { return }
            guard let next else {
                triageMessage = "No older unreviewed decisions match the current filters."
                return
            }
            if !requests.contains(where: { $0.id == next.id }) {
                requests.append(next)
                requests.sort {
                    $0.receivedAt == $1.receivedAt ? $0.id.uuidString > $1.id.uuidString : $0.receivedAt > $1.receivedAt
                }
            }
            if reviewFilter == .unreviewed { requests.removeAll { $0.id == id } }
            isTriaging = false
            await select(next.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func applyTriageReview(id: UUID, note: String) {
        noteIsDirty = false
        reviewState = .reviewed
        detail?.summary.reviewState = .reviewed
        detail?.summary.reviewNote = note
        if let index = requests.firstIndex(where: { $0.id == id }) {
            requests[index].reviewState = .reviewed
            requests[index].reviewNote = note
        }
    }

    public func setActive(_ active: Bool) async {
        isActive = false
        pauseReplay()
        if active {
            validateExpiry()
            isActive = true
            await refresh()
            if let selectedID, !noteIsDirty { await loadDetail(selectedID) }
        }
    }

    public func validateExpiry(now: Date = Date()) {
        guard !isUpdatingStar else { return }
        requests.removeAll { !$0.isRetained(at: now) }
        previews = previews.filter { $0.value.isRetained(at: now) }
        timeline?.removeExpired(now: now)
        if let detail, !detail.summary.isRetained(at: now) {
            beginSelection(nil)
            pauseReplay()
            errorMessage = "This decision reached the end of its seven-day retention period."
        }
        if timeline?.records.isEmpty == true { stopReplay() }
    }

    public func resetHistoryView() {
        stopReplay()
        beginSelection(nil)
        requests = []
        previews = [:]
        paginationCursor = nil
        newArrivalCount = 0
        usage = UsageSnapshot()
    }

    public func startReplay(range: Bool) async {
        guard !isSelecting else { return }
        do {
            let rows: [RequestSummary]
            if range {
                rows = try await store.replayCandidates(filter: filter)
            } else if let detail, let current = try await store.detail(id: detail.id) {
                rows = [current.summary]
            } else {
                rows = []
            }
            let newTimeline = try ReplayTimeline(records: rows)
            guard !newTimeline.records.isEmpty else { return }
            pauseReplay()
            timeline = newTimeline
            playbackDate = newTimeline.start
            skippedSeconds = 0
        } catch { errorMessage = error.localizedDescription }
    }

    public func pauseReplay() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }
    public func stopReplay() {
        pauseReplay()
        timeline = nil
    }
    public func seek(_ progress: Double) {
        pauseReplay()
        guard let timeline else { return }
        playbackDate = timeline.start.addingTimeInterval(min(1, max(0, progress)) * timeline.duration)
    }
    public func seekEvent(_ event: ReplayEvent) {
        guard let timeline else { return }
        seek(event.date.timeIntervalSince(timeline.start) / timeline.duration)
    }
    public func step(forward: Bool) {
        pauseReplay()
        guard let timeline else { return }
        playbackDate =
            (forward ? timeline.nextEvent(after: playbackDate) : timeline.previousEvent(before: playbackDate))
            ?? (forward ? timeline.end : timeline.start)
    }

    public func play() {
        guard timeline != nil, isActive else { return }
        if replayProgress >= 1 { seek(0) }
        isPlaying = true
        playbackTask = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let instant = ContinuousClock.now
                let elapsed = last.duration(to: instant).components
                last = instant
                guard let self, self.isPlaying else { return }
                self.advance(seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            }
        }
    }

    public func advance(seconds: Double, now: Date = Date()) {
        validateExpiry(now: now)
        guard let timeline, isPlaying, isActive else { return }
        var next = playbackDate.addingTimeInterval(max(0, seconds) * playbackSpeed)
        if skipIdle, let skip = timeline.nextAfterIdle(at: next) {
            skippedSeconds = skip.timeIntervalSince(next)
            next = skip
        }
        playbackDate = min(timeline.end, next)
        if playbackDate >= timeline.end { pauseReplay() }
        if followArrivals,
            let arrival = timeline.events.last(where: { $0.stage == .headers && $0.date <= playbackDate }),
            arrival.requestID != selectedID
        {
            beginSelection(arrival.requestID)
            Task { await loadDetail(arrival.requestID) }
        }
    }

    private func reveals(_ stage: ReplayStage) -> Bool {
        guard isActive, let detail, detail.summary.isRetained(at: Date()) else { return false }
        guard let timeline else { return true }
        return timeline.reveals(stage, record: detail.summary, at: playbackDate, now: Date())
    }

}
