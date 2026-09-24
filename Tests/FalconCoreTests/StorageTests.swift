import Foundation
import Testing
@testable import FalconCore

private struct StorageFixture {
    let directory: URL
    let runID = UUID()
    let store: DecisionStore

    init(budgetBytes: Int64 = FalconLimits.storageBytes) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FalconStorageTests-\(UUID().uuidString)")
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw FalconError("test_path_exists", "Test path already exists.") }
        store = try DecisionStore(path: directory.appendingPathComponent("store.sqlite").path,
                                  testRunID: runID, budgetBytes: budgetBytes)
    }

    func finish() async throws {
        #expect(try await store.testMarkerMatches(runID))
        guard try await store.testMarkerMatches(runID) else { throw FalconError("test_marker_mismatch", "Test cleanup refused.") }
        try FileManager.default.removeItem(at: directory)
    }
}

private func sampleDetail(id: UUID = UUID(), receivedAt: Date = Date(), status: RequestStatus = .accepted,
                          sourceID: UUID = UUID(), questionCount: Int = 1) -> RequestDetail {
    var summary = RequestSummary(id: id, sourceID: sourceID, keyID: UUID(), sourceName: "Agent",
                                 profileID: UUID(), profileName: "Upstream", receivedAt: receivedAt,
                                 status: status)
    summary.questionCount = questionCount
    summary.preview = "fixture"
    summary.timing.bodyReceivedMS = 1
    if status == .succeeded {
        summary.timing.upstreamStartedMS = 2
        summary.timing.responseReceivedMS = 7
        summary.timing.terminalMS = 10
        summary.inputTokens = 3
        summary.outputTokens = 2
    }
    let request = Data(#"{"questions":{"q":{"type":"noul","instructions":"synthetic"}}}"#.utf8)
    let response = status == .succeeded ? Data(#"{"answers":{"q":{"noul":0.7}}}"#.utf8) : nil
    return RequestDetail(summary: summary, receivedRequest: request, effectiveRequest: request, upstreamResponse: response)
}

private func projectedDetail(at time: Date, status: RequestStatus = .succeeded,
                             questions: [String: JSONValue], answers: [String: JSONValue],
                             requestedModel: String = "requested", resolvedModel: String? = nil,
                             inputTokens: Int? = nil, outputTokens: Int? = nil,
                             terminalMS: Double? = 10) throws -> RequestDetail {
    var summary = RequestSummary(sourceID: UUID(), keyID: UUID(), sourceName: "Synthetic",
                                 profileID: UUID(), profileName: "Synthetic", receivedAt: time,
                                 status: status, requestedModel: requestedModel)
    summary.questionCount = questions.count
    summary.resolvedModel = resolvedModel
    summary.inputTokens = inputTokens
    summary.outputTokens = outputTokens
    summary.timing.terminalMS = terminalMS
    if status == .succeeded { summary.timing.upstreamStartedMS = 1 }
    let request = try JSONValue.object(["questions": .object(questions)]).data()
    let response = status == .succeeded ? try JSONValue.object(["answers": .object(answers)]).data() : nil
    return RequestDetail(summary: summary, receivedRequest: request, effectiveRequest: request,
                         upstreamResponse: response)
}

private func persist(_ detail: RequestDetail, in store: DecisionStore) async throws {
    try await store.reserve(requestID: detail.id, requestBytes: detail.receivedRequest!.count,
                            questionCount: detail.summary.questionCount)
    try await store.insert(detail)
    try await store.release(requestID: detail.id)
}

@Test func storageRetentionAndLateCallbacks() async throws {
    let fixture = try StorageFixture()
    let store = fixture.store
    let detail = sampleDetail(receivedAt: Date().addingTimeInterval(-20))
    try await store.reserve(requestID: detail.id, requestBytes: detail.receivedRequest!.count, questionCount: 1)
    try await store.insert(detail)
    try await store.saveReview(id: detail.id, state: .flagged, note: "Check evidence")
    var completed = detail
    completed.summary.status = .succeeded
    completed.summary.timing.upstreamStartedMS = 2
    completed.summary.timing.responseReceivedMS = 5
    completed.summary.timing.terminalMS = 7
    completed.upstreamResponse = Data(#"{"answers":{"q":{"noul":0.7}}}"#.utf8)
    try await store.update(completed)
    #expect(try await store.detail(id: detail.id)?.summary.reviewState == .flagged)
    let expiry = detail.summary.expiresAt
    #expect(try await store.detail(id: detail.id, now: expiry.addingTimeInterval(-0.001)) != nil)
    #expect(try await store.detail(id: detail.id, now: expiry) == nil)
    #expect(try await store.requests(now: expiry).isEmpty)
    #expect(try await store.usage(now: expiry).requests == 0)
    try await store.cleanup(now: expiry)
    #expect(try await store.detail(id: detail.id, now: expiry.addingTimeInterval(-1)) == nil)
    await #expect(throws: (any Error).self) { try await store.update(detail) }
    await #expect(throws: (any Error).self) { try await store.saveReview(id: detail.id, state: .reviewed, note: "late") }
    try await store.release(requestID: detail.id)

    let late = sampleDetail()
    try await store.reserve(requestID: late.id, requestBytes: late.receivedRequest!.count, questionCount: 1)
    try await store.insert(late)
    try await store.clearHistory()
    await #expect(throws: (any Error).self) { try await store.update(late) }
    await #expect(throws: (any Error).self) { try await store.insert(late) }
    #expect(try await store.detail(id: late.id) == nil)
    try await store.release(requestID: late.id)
    try await fixture.finish()
}

@Test func storagePaginationRecoveryAndStatistics() async throws {
    let fixture = try StorageFixture()
    let store = fixture.store
    let time = Date().addingTimeInterval(-5)
    let source = UUID()
    let ids = (0..<3).map { _ in UUID() }
    var details = [sampleDetail(id: ids[0], receivedAt: time, status: .succeeded, sourceID: source),
                   sampleDetail(id: ids[1], receivedAt: time, status: .rejected, sourceID: source),
                   sampleDetail(id: ids[2], receivedAt: time, status: .accepted, sourceID: source)]
    details[1].summary.timing.terminalMS = 20
    for detail in details {
        try await store.reserve(requestID: detail.id, requestBytes: detail.receivedRequest!.count, questionCount: 1)
        try await store.insert(detail)
    }
    let first = try await store.requests(limit: 2)
    let second = try await store.requests(before: RequestCursor(receivedAt: first[1].receivedAt, id: first[1].id))
    #expect(first.count == 2)
    #expect(second.count == 1)
    #expect(Set(first.map(\.id) + second.map(\.id)) == Set(ids))
    let usage = try await store.usage()
    #expect(usage.requests == 3)
    #expect(usage.questions == 3)
    #expect(usage.terminal == 2)
    #expect(usage.failures == 1)
    #expect(usage.forwardedTerminal == 1)
    #expect(usage.completedQuestions == 1)
    #expect(usage.inputTokens == 3 && usage.outputTokens == 2)
    #expect(usage.p50MS == 10 && usage.p95MS == 20)
    #expect(usage.sources.first?.requests == 3)
    #expect(try await store.replayCandidates(filter: .init()).count == 2)
    await #expect(throws: (any Error).self) { try await store.replayCandidates(filter: .init(), limit: 1) }

    try await store.recoverInterrupted()
    #expect(try await store.detail(id: ids[2])?.summary.status == .interrupted)
    #expect(try await store.detail(id: ids[2])?.summary.timing.terminalMS == nil)
    for id in ids { try await store.release(requestID: id) }
    try await fixture.finish()
}

@Test func storageCapacityReservationsAreAtomic() async throws {
    let fixture = try StorageFixture(budgetBytes: 25_000_000)
    let store = fixture.store
    let ids = (0..<8).map { _ in UUID() }
    let accepted = await withTaskGroup(of: Bool.self) { group in
        for id in ids {
            group.addTask {
                do { try await store.reserve(requestID: id, requestBytes: 100, questionCount: 1); return true }
                catch { return false }
            }
        }
        var count = 0
        for await value in group { if value { count += 1 } }
        return count
    }
    #expect(accepted == 1)
    for id in ids { try await store.release(requestID: id) }
    #expect(try await store.storageBytes() > 0)
    #expect(throws: (any Error).self) {
        _ = try DecisionStore(path: fixture.directory.appendingPathComponent("store.sqlite").path,
                              testRunID: UUID(), budgetBytes: 25_000_000)
    }
    try await fixture.finish()
}

@Test func storageMaximumLegalBodiesFitReservedBudget() async throws {
    let fixture = try StorageFixture(budgetBytes: 80_000_000)
    let store = fixture.store
    let requestPrefix = #"{"questions":{"q":{"type":"noul","instructions":"synthetic"}},"padding":""#
    let responsePrefix = #"{"answers":{"q":{"noul":0.7}},"padding":""#
    let suffix = #""}"#
    let request = Data((requestPrefix + String(repeating: "x", count: FalconLimits.requestBytes - requestPrefix.utf8.count - suffix.utf8.count) + suffix).utf8)
    let response = Data((responsePrefix + String(repeating: "y", count: FalconLimits.responseBytes - responsePrefix.utf8.count - suffix.utf8.count) + suffix).utf8)
    #expect(request.count == FalconLimits.requestBytes)
    #expect(response.count == FalconLimits.responseBytes)
    var detail = sampleDetail()
    detail.receivedRequest = request
    detail.effectiveRequest = request
    try await store.reserve(requestID: detail.id, requestBytes: request.count, questionCount: 1)
    try await store.insert(detail)
    detail.summary.status = .succeeded
    detail.summary.timing.upstreamStartedMS = 2
    detail.summary.timing.responseReceivedMS = 5
    detail.summary.timing.terminalMS = 7
    detail.upstreamResponse = response
    try await store.update(detail)
    #expect(try await store.detail(id: detail.id)?.upstreamResponse?.count == FalconLimits.responseBytes)
    #expect(try await store.storageBytes() < 80_000_000)
    try await store.release(requestID: detail.id)
    try await fixture.finish()
}

@Test func storageCreatesSourceAndFirstKeyAtomically() async throws {
    let fixture = try StorageFixture()
    let store = fixture.store
    let profile = UpstreamProfile(name: "Synthetic", credentialID: "memory-only")
    try await store.saveProfile(profile)
    let first = AgentSource(name: "First", profileID: profile.id)
    let key = SourceKey(sourceID: first.id, digest: Data(repeating: 1, count: 32), suffix: "abcd")
    try await store.createSourceWithKey(first, key: key)
    let second = AgentSource(name: "Second", profileID: profile.id)
    let collision = SourceKey(id: key.id, sourceID: second.id, digest: Data(repeating: 2, count: 32), suffix: "efgh")
    await #expect(throws: (any Error).self) { try await store.createSourceWithKey(second, key: collision) }
    #expect(try await store.sources().map(\.id) == [first.id])
    #expect(try await store.sourceKeys().map(\.id) == [key.id])
    try await fixture.finish()
}

@Test func storageSearchCoversHistoryBeforePagination() async throws {
    let fixture = try StorageFixture()
    let store = fixture.store
    let start = Date().addingTimeInterval(-200)
    var oldest: UUID?
    for index in 0..<130 {
        var detail = sampleDetail(receivedAt: start.addingTimeInterval(Double(index)))
        detail.summary.preview = index == 0 ? "needle deep-match" : "needle"
        if index == 0 { oldest = detail.id }
        try await store.reserve(requestID: detail.id, requestBytes: detail.receivedRequest!.count, questionCount: 1)
        try await store.insert(detail)
        try await store.release(requestID: detail.id)
    }
    let first = try await store.requests(filter: DecisionFilter(search: "needle"), limit: 100)
    let second = try await store.requests(filter: DecisionFilter(search: "needle"),
                                          before: RequestCursor(receivedAt: first.last!.receivedAt, id: first.last!.id), limit: 100)
    #expect(first.count == 100)
    #expect(second.count == 30)
    #expect(Set(first.map(\.id) + second.map(\.id)).count == 130)
    #expect(try await store.requests(filter: DecisionFilter(search: "deep-match")).map(\.id) == [oldest!])
    #expect(try await store.usage(filter: DecisionFilter(search: "deep-match")).requests == 1)
    try await fixture.finish()
}

@Test func storageEightMaximumPayloadReservationsRemainBounded() async throws {
    let fixture = try StorageFixture(budgetBytes: 500_000_000)
    let store = fixture.store
    let requestPrefix = #"{"questions":{"q":{"type":"noul","instructions":"synthetic"}},"padding":""#
    let responsePrefix = #"{"answers":{"q":{"noul":0.7}},"padding":""#
    let suffix = #""}"#
    let request = Data((requestPrefix + String(repeating: "x", count: FalconLimits.requestBytes - requestPrefix.utf8.count - suffix.utf8.count) + suffix).utf8)
    let response = Data((responsePrefix + String(repeating: "y", count: FalconLimits.responseBytes - responsePrefix.utf8.count - suffix.utf8.count) + suffix).utf8)
    let ids = (0..<8).map { _ in UUID() }
    let admitted = await withTaskGroup(of: Bool.self) { group in
        for id in ids {
            group.addTask {
                do { try await store.reserve(requestID: id, requestBytes: request.count, questionCount: 1); return true }
                catch { return false }
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(admitted.count == 8 && admitted.allSatisfy { $0 })
    let before = try await store.capacityUsage()
    #expect(before.physicalBytes + before.reservedBytes <= before.budgetBytes)
    for id in ids {
        var detail = sampleDetail(id: id)
        detail.receivedRequest = request
        detail.effectiveRequest = request
        try await store.insert(detail)
        detail.summary.status = .succeeded
        detail.summary.timing.upstreamStartedMS = 2
        detail.summary.timing.responseReceivedMS = 5
        detail.summary.timing.terminalMS = 7
        detail.upstreamResponse = response
        try await store.update(detail)
    }
    let after = try await store.capacityUsage()
    #expect(after.physicalBytes < after.budgetBytes)
    #expect(after.physicalBytes + after.reservedBytes <= after.budgetBytes)
    for id in ids { try await store.release(requestID: id) }
    #expect(try await store.capacityUsage().reservedBytes == 0)
    try await fixture.finish()
}

@Test func storageProjectedStatisticsAndSharedEvidenceFilters() async throws {
    let fixture = try StorageFixture()
    let store = fixture.store
    let hour = floor(Date().timeIntervalSince1970 / 3_600) * 3_600 - 3_600
    let since = Date(timeIntervalSince1970: hour)
    let until = since.addingTimeInterval(3_600)
    let choice = JSONValue.object(["type": .string("choice"), "instructions": .string("Pick one"),
                                   "criteria": .object(["a": .string("Alpha"), "b": .string("Beta")])])
    let choiceWithExtension = JSONValue.object(["type": .string("choice"), "instructions": .string("Pick one"),
                                                "criteria": .object(["a": .string("Alpha"), "b": .string("Beta")]),
                                                "unrelated": .string("ignored")])
    let score = JSONValue.object(["type": .string("score"), "instructions": .string("Rate it"),
                                  "criteria": .array([.string("Poor"), .string("Good")])])
    let noul = JSONValue.object(["type": .string("noul"), "instructions": .string("Is it ready?")])
    let first = try projectedDetail(at: since.addingTimeInterval(60),
        questions: ["choice-a": choiceWithExtension, "score-a": score, "noul-a": noul],
        answers: ["choice-a": .object(["choice": .string("a"), "confidence": .number(0.1)]),
                  "score-a": .object(["score": .number(0.5), "confidence": .number(1)]),
                  "noul-a": .object(["noul": .number(1)])],
        requestedModel: "requested-a", resolvedModel: "resolved-a", inputTokens: 10, outputTokens: 4)
    let second = try projectedDetail(at: since.addingTimeInterval(660),
        questions: ["choice-b": choice, "score-b": score, "noul-b": noul],
        answers: ["choice-b": .object(["choice": .string("b"), "confidence": .number(0.9)]),
                  "score-b": .object(["score": .number(1.5), "confidence": .number(0.1)]),
                  "noul-b": .object(["noul": .number(0)])],
        requestedModel: "requested-b", outputTokens: 6, terminalMS: 20)
    let failed = try projectedDetail(at: since.addingTimeInterval(1_260), status: .rejected,
        questions: ["choice-c": choice], answers: [:], terminalMS: nil)
    for detail in [first, second, failed] { try await persist(detail, in: store) }
    try await store.updateDelivery(id: first.id, state: .written, finishedMS: 120)
    try await store.updateDelivery(id: failed.id, state: .failed, finishedMS: 70)

    let filter = DecisionFilter(since: since, until: until)
    let usage = try await store.usage(filter: filter)
    #expect(usage.requests == 3 && usage.questions == 7 && usage.completedQuestions == 6)
    #expect(usage.terminal == 3 && usage.failures == 1 && usage.forwardedTerminal == 2 && usage.succeeded == 2)
    #expect(usage.inputTokens == 10 && usage.outputTokens == 10 && usage.unknownUsage == 2)
    #expect(usage.p50MS == 10 && usage.p95MS == 20 && usage.latencySamples == 2 && usage.missingLatency == 1)
    #expect(usage.returnP50MS == 120 && usage.returnP95MS == 120)
    #expect(usage.returnLatencySamples == 1 && usage.missingReturnLatency == 2)
    #expect(usage.processingLatencies.reduce(0) { $0 + $1.count } == 2)
    #expect(usage.returnLatencies.reduce(0) { $0 + $1.count } == 1)
    #expect(usage.models.map(\.name) == ["requested", "requested-b", "resolved-a"])
    #expect(usage.sources.first { $0.id == first.summary.sourceID }?.lastReceivedAt == first.summary.receivedAt)
    #expect(Dictionary(uniqueKeysWithValues: usage.questionTypes.map { ($0.name, $0.count) }) ==
            ["choice": 3, "score": 2, "noul": 2])
    #expect(usage.confidence.map(\.count) == [0, 2, 0, 0, 0, 0, 0, 0, 0, 2])
    #expect(usage.noul.map(\.count) == [1, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    #expect(usage.missingConfidence == 0 && usage.missingNoul == 0)
    #expect(usage.bucketSeconds == 300 && usage.buckets.count == 12)
    #expect(usage.buckets.map(\.requests).reduce(0, +) == 3)
    #expect(usage.buckets.map(\.failures).reduce(0, +) == 1)
    #expect(usage.buckets.map(\.inputTokens).reduce(0, +) == 10)
    #expect(usage.buckets.map(\.outputTokens).reduce(0, +) == 10)
    #expect(usage.buckets.filter { $0.requests == 0 }.count == 9)
    let hourly = try await store.usage(filter: DecisionFilter(since: since.addingTimeInterval(-3_600), until: until))
    #expect(hourly.bucketSeconds == 3_600 && hourly.buckets.count == 2)
    #expect(hourly.buckets.map(\.requests) == [0, 3])
    let daily = try await store.usage(filter: DecisionFilter(since: since.addingTimeInterval(-172_800), until: until))
    #expect(daily.bucketSeconds == 86_400)
    #expect(daily.buckets.map(\.requests).reduce(0, +) == 3)
    #expect(daily.buckets.contains { $0.requests == 0 })
    #expect(usage.decisionGroups.count == 3 && usage.omittedDecisionGroups == 0)
    let choiceGroup = try #require(usage.decisionGroups.first { $0.type == "choice" })
    #expect(choiceGroup.samples == 2 && choiceGroup.outcomes.map(\.name) == ["a", "b"])
    #expect(choiceGroup.outcomes.map(\.count) == [1, 1])
    let scoreGroup = try #require(usage.decisionGroups.first { $0.type == "score" })
    #expect(scoreGroup.samples == 2 && scoreGroup.mean == 1 && scoreGroup.minimum == 0.5 && scoreGroup.maximum == 1.5)
    let noulGroup = try #require(usage.decisionGroups.first { $0.type == "noul" })
    #expect(noulGroup.samples == 2 && noulGroup.mean == 0.5 && noulGroup.minimum == 0 && noulGroup.maximum == 1)

    let evidence = DecisionFilter(since: since, until: until,
                                  questionFingerprint: choiceGroup.fingerprint.lowercased(), confidenceBand: 1)
    #expect(try await store.requests(filter: evidence).map(\.id) == [first.id])
    #expect(try await store.usage(filter: evidence).requests == 1)
    #expect(try await store.replayCandidates(filter: evidence).map(\.id) == [first.id])
    #expect(try await store.requests(filter: DecisionFilter(since: since, until: until, noulBand: 9)).map(\.id) == [first.id])
    #expect(try await store.requests(filter: DecisionFilter(since: since, until: until,
        questionFingerprint: scoreGroup.fingerprint, confidenceBand: 9)).map(\.id) == [first.id])
    await #expect(throws: (any Error).self) { try await store.requests(filter: DecisionFilter(confidenceBand: 10)) }
    await #expect(throws: (any Error).self) { try await store.usage(filter: DecisionFilter(questionFingerprint: "not-hex")) }
    try await fixture.finish()
}

@Test func storageFingerprintSemanticsUnknownsAndGroupLimit() async throws {
    let fixture = try StorageFixture()
    let store = fixture.store
    let time = Date().addingTimeInterval(-30)
    let score = JSONValue.object(["type": .string("score"), "instructions": .string("Rate"),
                                  "criteria": .array([.string("Low"), .string("High")])])
    let reversed = JSONValue.object(["type": .string("score"), "instructions": .string("Rate"),
                                     "criteria": .array([.string("High"), .string("Low")])])
    var questions: [String: JSONValue] = ["score-a": score, "score-b": reversed,
                                          "missing-choice": .object(["type": .string("choice"),
                                            "instructions": .string("Unknown"), "criteria": .object(["a": .string("A"), "b": .string("B")])]),
                                          "missing-noul": .object(["type": .string("noul"), "instructions": .string("Unknown")])]
    var answers: [String: JSONValue] = ["score-a": .object(["score": .number(0), "confidence": .number(0)]),
                                         "score-b": .object(["score": .number(1), "confidence": .number(1)]),
                                         "missing-choice": .object(["choice": .string("a")]),
                                         "missing-noul": .object([:])]
    for index in 0..<101 {
        let id = "noul-\(index)"
        questions[id] = .object(["type": .string("noul"), "instructions": .string("Distinct \(index)")])
        answers[id] = .object(["noul": .number(0.5)])
    }
    questions["duplicate"] = questions["noul-0"]
    answers["duplicate"] = .object(["noul": .number(0.5)])
    let detail = try projectedDetail(at: time, questions: questions, answers: answers)
    try await persist(detail, in: store)
    let usage = try await store.usage()
    #expect(usage.missingConfidence == 1 && usage.missingNoul == 1)
    #expect(usage.confidence[0].count == 1 && usage.confidence[9].count == 1)
    #expect(usage.decisionGroups.count == 100 && usage.omittedDecisionGroups == 5)
    #expect(usage.decisionGroups.first?.samples == 2)
    let scoreGroups = try await store.usage(filter: DecisionFilter(since: time.addingTimeInterval(-1), until: Date()))
        .decisionGroups.filter { $0.type == "score" }
    #expect(scoreGroups.count == 2)
    #expect(scoreGroups[0].fingerprint != scoreGroups[1].fingerprint)
    try await fixture.finish()
}
