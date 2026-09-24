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
    public var hours = 168
    public var usageShowsTokens = false
    public var usageShowsReturn = false
    public var usageScrollID: String?
    public var selectedID: UUID?
    public private(set) var requests: [RequestSummary] = []
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

    public init(store: DecisionStore, configuration: ConfigurationManager? = nil, preview: Bool = false) {
        self.store = store
        self.configuration = configuration
        self.isPreview = preview
    }

    public var filter: DecisionFilter {
        DecisionFilter(
            since: timeRange?.start ?? filterAnchor.addingTimeInterval(-Double(hours) * 3600),
            until: timeRange?.end ?? filterAnchor, sourceIDs: sourceFilters, status: statusFilter,
            reviewState: reviewFilter, search: search, questionFingerprint: fingerprintFilter,
            confidenceBand: confidenceFilter, noulBand: noulFilter)
    }

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
    public var visibleStatus: String {
        guard let detail else { return "No selection" }
        if timeline == nil || terminalVisible { return detail.summary.status.title }
        if resultsVisible { return "Response received" }
        if reveals(.upstream) { return "Waiting for Jev" }
        if inputsVisible { return "Preparing request" }
        return reveals(.headers) ? "Receiving input" : "Not yet received"
    }
    public var selectedEvents: [ReplayEvent] { timeline?.events.filter { $0.requestID == selectedID } ?? [] }

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
            let loadedIDs = Set(requests.map(\.id))
            let arrivals = fetched.filter {
                !loadedIDs.contains($0.id) && $0.receivedAt >= (requests.first?.receivedAt ?? .distantFuture)
            }
            let holdPosition = !reset && !requests.isEmpty && (timeline != nil || selectedID != requests.first?.id)
            if holdPosition && !arrivals.isEmpty {
                newArrivalCount = arrivals.count
                let updates = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
                requests = requests.map { updates[$0.id] ?? $0 }
            } else if reset || requests.count <= 100 {
                newArrivalCount = 0
                requests = fetched
                hasMore = fetched.count == 100
            } else {
                let newIDs = Set(fetched.map(\.id))
                requests =
                    fetched
                    + requests.filter {
                        !newIDs.contains($0.id) && $0.expiresAt > Date()
                            && $0.receivedAt >= (query.since ?? .distantPast)
                    }
            }
            if selectedID == nil, let first = requests.first {
                await select(first.id)
            } else if reset, let selectedID, !requests.contains(where: { $0.id == selectedID }) {
                await select(requests.first?.id)
            } else if let detail, let updated = fetched.first(where: { $0.id == detail.id }), updated != detail.summary,
                !noteIsDirty
            {
                await loadDetail(detail.id)
            }
        } catch { if revision == refreshRevision { errorMessage = error.localizedDescription } }
    }

    public func loadMore() async {
        guard let last = requests.last, hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let query = filter
            let rows = try await store.requests(
                filter: query, before: RequestCursor(receivedAt: last.receivedAt, id: last.id))
            guard query == filter else { return }
            let ids = Set(requests.map(\.id))
            requests += rows.filter { !ids.contains($0.id) }
            hasMore = rows.count == 100
        } catch { errorMessage = error.localizedDescription }
    }

    public func showLatest() async {
        if noteIsDirty {
            await saveReview()
            if noteIsDirty { return }
        }
        await refresh(reset: true)
        await select(requests.first?.id)
    }

    public func select(_ id: UUID?) async {
        if noteIsDirty {
            await saveReview()
            if noteIsDirty { return }
        }
        pauseReplay()
        followArrivals = false
        selectedID = id
        detail = nil
        presentation = nil
        selectionRevision += 1
        if let id { await loadDetail(id) }
    }

    private func loadDetail(_ id: UUID) async {
        let revision = selectionRevision
        do {
            let loaded = try await store.detail(id: id)
            guard revision == selectionRevision, selectedID == id, isActive else { return }
            let parsed = await Task.detached { loaded.map(DecisionPresentation.init(detail:)) }.value
            guard revision == selectionRevision, selectedID == id, isActive else { return }
            detail = loaded
            presentation = parsed
            note = loaded?.summary.reviewNote ?? ""
            reviewState = loaded?.summary.reviewState ?? .unreviewed
            noteIsDirty = false
            validateExpiry()
        } catch {
            errorMessage = error.localizedDescription
            pauseReplay()
        }
    }

    public func editNote(_ value: String) {
        note = value
        noteIsDirty = true
    }
    public func editReview(_ value: ReviewState) {
        reviewState = value
        noteIsDirty = true
    }
    public func saveReview() async {
        guard let id = detail?.id, isActive else { return }
        do {
            let savedNote = note
            let savedState = reviewState
            try await store.saveReview(id: id, state: savedState, note: savedNote)
            guard detail?.id == id, note == savedNote, reviewState == savedState else { return }
            noteIsDirty = false
            await loadDetail(id)
        } catch { errorMessage = error.localizedDescription }
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
        requests.removeAll { $0.expiresAt <= now }
        timeline?.removeExpired(now: now)
        if let detail, detail.summary.expiresAt <= now {
            self.detail = nil
            presentation = nil
            note = ""
            noteIsDirty = false
            selectedID = nil
            pauseReplay()
            errorMessage = "This decision reached the end of its seven-day retention period."
        }
        if timeline?.records.isEmpty == true { stopReplay() }
    }

    public func resetHistoryView() {
        selectionRevision += 1
        stopReplay()
        detail = nil
        presentation = nil
        requests = []
        newArrivalCount = 0
        selectedID = nil
        note = ""
        noteIsDirty = false
        usage = UsageSnapshot()
    }

    public func testConnection(profileID: UUID, service: DecisionService) async {
        guard !isPreview, let configuration else { return }
        do {
            guard let profile = try await store.profiles().first(where: { $0.id == profileID }) else {
                throw FalconError("profile_missing", "The connection is no longer available.")
            }
            let issued = try await configuration.createSource(name: "Falcon connection check", profileID: profileID)
            let input = try JSONValue.object([
                "model": .string(profile.defaultModel),
                "state": .object(["purpose": .string("Synthetic connection check"), "synthetic": .bool(true)]),
                "questions": .object([
                    "input_kind": .object([
                        "type": .string("choice"), "instructions": .string("Classify this fixed input."),
                        "criteria": .object([
                            "synthetic": .string("An explicitly synthetic check."), "real": .string("A real task."),
                        ]),
                    ])
                ]),
            ]).data()
            let reply = await service.submit(
                token: issued.token, body: input, transport: .app, metadata: ["intent": "connection_check"])
            try await configuration.revokeKey(sourceID: issued.source.id)
            var archived = issued.source
            archived.archived = true
            try await configuration.saveSource(archived)
            clearEvidenceFilters()
            sourceFilters = [issued.source.id]
            statusFilter = nil
            reviewFilter = nil
            search = ""
            hours = 168
            page = .decisions
            await refresh(reset: true)
            if let id = reply.requestID { await select(id) }
            if reply.status != 200 {
                errorMessage =
                    reply.error?.message ?? "The upstream returned HTTP \(reply.status). Inspect the recorded response."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    public func startReplay(range: Bool) async {
        do {
            let rows: [RequestSummary]
            if range {
                rows = try await store.replayCandidates(filter: filter)
            } else {
                rows = detail.map { [$0.summary] } ?? []
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
            selectedID = arrival.requestID
            selectionRevision += 1
            detail = nil
            presentation = nil
            Task { await loadDetail(arrival.requestID) }
        }
    }

    public func exportJSON() async throws -> Data {
        guard let id = selectedID, isActive else { throw FalconError("no_selection", "Select a decision first.") }
        guard timeline == nil else {
            throw FalconError("replay_export", "Show the final result before exporting the complete record.")
        }
        let record = try await store.detail(id: id)
        guard let record, record.summary.expiresAt > Date() else {
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
        return DecisionFormat.csv(records.filter { $0.expiresAt > Date() })
    }

    private func reveals(_ stage: ReplayStage) -> Bool {
        guard isActive, let detail, detail.summary.expiresAt > Date() else { return false }
        guard let timeline else { return true }
        return timeline.reveals(stage, record: detail.summary, at: playbackDate, now: Date())
    }

}
