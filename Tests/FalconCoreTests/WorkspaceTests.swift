import Foundation
import Testing

@testable import FalconCore

private struct WorkspaceFixture {
    let directory: URL
    let marker = UUID()
    let store: DecisionStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FalconWorkspaceTests-\(UUID())")
        store = try DecisionStore(path: directory.appendingPathComponent("history.sqlite").path, testRunID: marker)
    }

    func insert(_ records: [RequestDetail]) async throws {
        for record in records {
            try await store.reserve(
                requestID: record.id,
                requestBytes: max(record.receivedRequest?.count ?? 0, record.effectiveRequest?.count ?? 0),
                questionCount: record.summary.questionCount)
            try await store.insert(record)
            try await store.release(requestID: record.id)
        }
    }

    func finish() async throws {
        guard try await store.testMarkerMatches(marker) else {
            throw FalconError("test_marker", "Refuse to clean an unmarked fixture.")
        }
        try FileManager.default.removeItem(at: directory)
    }
}

@MainActor @Test func workspaceQueriesPaginationAndReviewPersistence() async throws {
    let fixture = try WorkspaceFixture()
    var records = try PreviewData.records()
    let template = records[0]
    for index in 40..<105 {
        var record = template
        record.summary.id = UUID()
        record.summary.receivedAt = template.summary.receivedAt.addingTimeInterval(-Double(index * 150))
        record.summary.expiresAt = record.summary.receivedAt.addingTimeInterval(FalconLimits.retention)
        records.append(record)
    }
    try await fixture.insert(records)
    let model = WorkspaceModel(store: fixture.store)
    await model.refresh(reset: true)
    #expect(model.requests.count == 100)
    #expect(model.hasMore)
    #expect(model.usage.requests == 105)
    await model.loadMore()
    #expect(model.requests.count == 105)
    #expect(!model.hasMore)
    await model.refresh()
    #expect(model.requests.count == 105)
    #expect(!model.hasMore)
    let selected = try #require(model.detail)
    #expect(model.inputsVisible && model.resultsVisible)
    model.editNote("Inspect this routing boundary")
    model.editReview(.flagged)
    await model.select(records[1].id)
    let saved = try await fixture.store.detail(id: selected.id)
    #expect(saved?.summary.reviewNote == "Inspect this routing boundary")
    #expect(saved?.summary.reviewState == .flagged)
    #expect(model.selectedID == records[1].id)
    #expect(!model.noteIsDirty)
    model.sourceFilters = [records[1].summary.sourceID, records[2].summary.sourceID]
    model.statusFilter = .succeeded
    await model.refresh(reset: true)
    #expect(model.requests.allSatisfy { model.sourceFilters.contains($0.sourceID) && $0.status == .succeeded })
    model.sourceFilters = []
    model.reviewFilter = .flagged
    model.search = "routing boundary"
    await model.refresh(reset: true)
    #expect(model.requests.map(\.id) == [selected.id])
    model.search = "not-in-this-fixture"
    await model.refresh(reset: true)
    #expect(model.requests.isEmpty)
    #expect(model.detail == nil)
    #expect(model.selectedID == nil)
    try await fixture.finish()
}

@MainActor @Test func workspaceFailedReviewPreservesDraftAndSelection() async throws {
    let fixture = try WorkspaceFixture()
    let records = try Array(PreviewData.records().prefix(2))
    try await fixture.insert(records)
    let model = WorkspaceModel(store: fixture.store)
    await model.refresh(reset: true)
    let first = try #require(model.selectedID)
    model.editNote(String(repeating: "x", count: 4097))
    await model.select(records[1].id)
    #expect(model.noteIsDirty)
    #expect(model.selectedID == first)
    #expect(model.note.utf8.count == 4097)
    #expect(model.errorMessage != nil)
    model.editNote("Corrected")
    await model.saveReview()
    #expect(!model.noteIsDirty)
    #expect(model.detail?.summary.reviewNote == "Corrected")
    await model.setActive(false)
    #expect(!model.inputsVisible && !model.resultsVisible)
    model.editNote("Saved after return")
    await model.saveReview()
    #expect(model.noteIsDirty)
    await model.setActive(true)
    #expect(model.note == "Saved after return")
    #expect(model.noteIsDirty)
    await model.saveReview()
    #expect(!model.noteIsDirty)
    try await fixture.finish()
}

@MainActor @Test func workspaceSelectionKeepsEvidenceUntilReplacementIsReady() async throws {
    let fixture = try WorkspaceFixture()
    let records = try Array(PreviewData.records().prefix(3))
    try await fixture.insert(records)
    let model = WorkspaceModel(store: fixture.store)
    await model.refresh(reset: true)
    let initial = try #require(model.detail)
    model.beginSelection(records[1].id)
    #expect(model.isSelecting)
    #expect(model.detail == initial && model.presentation != nil)
    model.editNote("Must not apply to a different selection")
    model.editReview(.flagged)
    #expect(!model.noteIsDirty && model.reviewState == initial.summary.reviewState)
    await #expect(throws: FalconError.self) { try await model.exportJSON() }
    await model.saveReview()
    #expect(try await fixture.store.detail(id: initial.id)?.summary.reviewNote == initial.summary.reviewNote)
    async let earlier: Void = model.select(records[1].id)
    await model.select(records[2].id)
    await earlier
    #expect(!model.isSelecting)
    #expect(model.selectedID == model.detail?.id)
    #expect(model.presentation?.state != nil)
    await model.select(UUID())
    #expect(!model.isSelecting && model.detail != nil)
    #expect(model.selectedID == model.detail?.id && model.errorMessage != nil)
    await model.select(nil)
    #expect(model.selectedID == nil && model.detail == nil && model.presentation == nil)
    #expect(!model.isSelecting && model.note.isEmpty)
    try await fixture.finish()
}

@MainActor @Test func workspaceHoldsReviewDuringArrivalsAndRefreshesOlderInflight() async throws {
    let fixture = try WorkspaceFixture()
    var records = try Array(PreviewData.records().prefix(2))
    let completed = records[1]
    records[1].summary.status = .inFlight
    records[1].summary.timing.responseReceivedMS = nil
    records[1].summary.timing.terminalMS = nil
    records[1].summary.timing.deliveryFinishedMS = nil
    records[1].upstreamResponse = nil
    try await fixture.insert(records)
    let model = WorkspaceModel(store: fixture.store)
    await model.refresh(reset: true)
    await model.select(records[1].id)
    model.editNote("Keep the current reading position")
    let arrivals = (0..<101).map { index in
        var record = records[0]
        record.summary.id = UUID()
        record.summary.receivedAt = Date().addingTimeInterval(-Double(index) / 10 - 1)
        record.summary.expiresAt = record.summary.receivedAt.addingTimeInterval(FalconLimits.retention)
        return record
    }
    try await fixture.insert(arrivals)
    await model.refresh()
    #expect(model.newArrivalCount == 100)
    #expect(model.requests.map(\.id) == records.map(\.id))
    #expect(model.selectedID == records[1].id && model.noteIsDirty)
    await model.saveReview()
    try await fixture.store.reserve(
        requestID: completed.id, requestBytes: completed.effectiveRequest?.count ?? 0,
        questionCount: completed.summary.questionCount)
    try await fixture.store.update(completed)
    try await fixture.store.release(requestID: completed.id)
    await model.refresh()
    #expect(model.detail?.summary.status == .succeeded)
    #expect(model.note == "Keep the current reading position")
    await model.showLatest()
    #expect(model.newArrivalCount == 0)
    #expect(model.selectedID == arrivals[0].id)
    await model.selectAdjacent(forward: false)
    #expect(model.selectedID == arrivals[0].id)
    await model.selectAdjacent(forward: true)
    #expect(model.selectedID == arrivals[1].id)
    try await fixture.finish()
}

@MainActor @Test func workspaceReplayUsesStoredEvidenceAndWallClockExpiry() async throws {
    let fixture = try WorkspaceFixture()
    var records = try Array(PreviewData.records().prefix(2))
    let nearExpiry = Date().addingTimeInterval(-FalconLimits.retention + 20)
    for index in records.indices {
        records[index].summary.receivedAt = nearExpiry.addingTimeInterval(Double(index * 2))
        records[index].summary.expiresAt = records[index].summary.receivedAt.addingTimeInterval(FalconLimits.retention)
    }
    try await fixture.insert(records)
    let model = WorkspaceModel(store: fixture.store)
    await model.refresh(reset: true)
    await model.select(records[0].id)
    await model.startReplay(range: false)
    #expect(model.timeline?.records.count == 1)
    #expect(!model.inputsVisible && !model.resultsVisible)
    #expect(model.visibleStatus == "Receiving input")
    #expect(!model.terminalVisible && !model.deliveryVisible)
    model.step(forward: true)
    #expect(model.inputsVisible && !model.resultsVisible)
    #expect(model.visibleStatus == "Preparing request")
    model.step(forward: true)
    #expect(model.visibleStatus == "Waiting for Jev")
    model.step(forward: true)
    #expect(model.resultsVisible)
    #expect(model.visibleStatus == "Response received")
    #expect(!model.terminalVisible && !model.deliveryVisible)
    model.step(forward: false)
    #expect(!model.resultsVisible)
    model.seek(1)
    #expect(model.replayProgress == 1)
    #expect(model.visibleStatus == "Completed")
    #expect(model.terminalVisible && model.deliveryVisible)
    model.play()
    #expect(model.replayProgress == 0)
    model.advance(seconds: 0.01)
    #expect(model.inputsVisible)
    model.pauseReplay()
    await model.startReplay(range: true)
    #expect(model.timeline?.records.count == 2)
    model.followArrivals = true
    model.playbackSpeed = 4
    model.play()
    model.advance(seconds: 0.6)
    #expect(model.selectedID == records[1].id)
    await model.setActive(false)
    #expect(!model.isPlaying)
    #expect(!model.inputsVisible)
    await model.setActive(true)
    model.seek(0)
    model.validateExpiry(now: records[1].summary.expiresAt)
    #expect(model.timeline == nil)
    #expect(model.detail == nil)
    #expect(model.presentation == nil)
    #expect(model.note.isEmpty)
    #expect(model.errorMessage?.contains("retention") == true)
    #expect(try await fixture.store.requests().count == 2)
    model.resetHistoryView()
    #expect(model.requests.isEmpty && model.usage.requests == 0)
    #expect(!model.isPlaying)
    try await fixture.finish()
}

@MainActor @Test func workspaceExportRetainsOriginalBytesAndExactRange() async throws {
    let fixture = try WorkspaceFixture()
    var records = try Array(PreviewData.records().prefix(3))
    records[0].receivedRequest = Data(" { \"state\": \"exact spacing\" } \n".utf8)
    try await fixture.insert(records)
    let model = WorkspaceModel(store: fixture.store)
    await model.refresh(reset: true)
    await model.select(records[0].id)
    let exported = try JSONValue.decode(await model.exportJSON())
    let encoded = try #require(exported["received_request"]?["original_base64"]?.stringValue)
    #expect(Data(base64Encoded: encoded) == records[0].receivedRequest)
    model.timeRange = DateInterval(start: records[1].summary.receivedAt, end: records[0].summary.receivedAt)
    await model.refresh(reset: true)
    #expect(model.requests.map(\.id) == [records[1].id])
    model.fingerprintFilter = try #require(model.usage.decisionGroups.first { $0.questionID == "execution_mode" })
        .fingerprint
    model.confidenceFilter = 7
    let csv = try await model.exportCSV()
    #expect(csv.components(separatedBy: "\r\n").count == 2)
    #expect(csv.contains(records[1].id.uuidString))
    #expect(!csv.contains(records[0].id.uuidString))
    model.fingerprintFilter = "a"
    model.confidenceFilter = 4
    model.noulFilter = 1
    #expect(model.hasEvidenceFilter)
    model.clearEvidenceFilters()
    #expect(!model.hasEvidenceFilter)
    await model.refresh(reset: true)
    let bucket = try #require(model.usage.buckets.first)
    model.inspectBucket(bucket)
    #expect(model.timeRange?.start == bucket.date)
    #expect(model.timeRange?.duration == model.usage.bucketSeconds)
    await model.setActive(false)
    await #expect(throws: (any Error).self) { try await model.exportJSON() }
    await #expect(throws: (any Error).self) { try await model.exportCSV() }
    try await fixture.finish()
}

@MainActor @Test func workspaceConnectionCheckIsExplicitAuditedAndRevoked() async throws {
    let fixture = try WorkspaceFixture()
    let configuration = ConfigurationManager(store: fixture.store, vault: .memory())
    let profile = try await configuration.saveProfile(
        UpstreamProfile(name: "Synthetic", baseURL: "https://synthetic.example.test"), apiKey: "synthetic-upstream")
    let response = Data(
        #"""
        {"model":"jev-fixture","answers":{
          "input_kind":{"type":"choice","choice":"synthetic",
            "probabilities":{"synthetic":0.99,"real":0.01},"confidence":0.92}
        },"usage":{"input_tokens":4,"output_tokens":2}}
        """#.utf8)
    let client = JevClient { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-upstream")
        let input = try JSONValue.decode(#require(request.httpBody))
        #expect(input["state"]?["synthetic"] == .bool(true))
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        return (response, http)
    }
    let service = DecisionService(store: fixture.store, configuration: configuration, client: client)
    let model = WorkspaceModel(store: fixture.store, configuration: configuration)
    #expect(try await fixture.store.requests().isEmpty)
    await model.testConnection(profileID: profile.id, service: service)
    #expect(model.page == .decisions)
    #expect(model.detail?.summary.transport == .app)
    #expect(model.detail?.summary.status == .succeeded)
    #expect(model.detail?.summary.metadata["intent"] == "connection_check")
    #expect(model.sources.count == 1 && model.sources[0].archived)
    #expect(model.keys.count == 1 && model.keys[0].revokedAt != nil)
    #expect(model.detail?.summary.delivery == .unknown)
    let checkID = try #require(model.selectedID)
    var arrival = try #require(PreviewData.records().first)
    arrival.summary.receivedAt = Date()
    arrival.summary.expiresAt = arrival.summary.receivedAt.addingTimeInterval(FalconLimits.retention)
    try await fixture.insert([arrival])
    await model.refresh()
    #expect(model.requests.count == 2)
    #expect(model.requests.contains { $0.id == arrival.id })
    #expect(model.selectedID == checkID)
    await service.shutdown()
    try await fixture.finish()
}
