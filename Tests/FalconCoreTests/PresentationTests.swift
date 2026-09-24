import Foundation
import Testing

@testable import FalconCore

private func sampleRecord() -> RequestSummary {
    RequestSummary(
        sourceID: UUID(), keyID: UUID(), sourceName: "Fixture", profileID: UUID(), profileName: "Local",
        receivedAt: Date(timeIntervalSince1970: 1000), status: .succeeded)
}

@Test func playbackPreservesInputArrivalAndUnknownTiming() throws {
    var first = sampleRecord()
    first.timing = RequestTiming(bodyReceivedMS: 500, upstreamStartedMS: 510, responseReceivedMS: 900, terminalMS: 905)
    var second = sampleRecord()
    second.receivedAt = first.receivedAt.addingTimeInterval(5)
    second.timing = RequestTiming(bodyReceivedMS: 20, upstreamStartedMS: 25)
    second.status = .interrupted
    let now = first.receivedAt.addingTimeInterval(10)
    var timeline = try ReplayTimeline(records: [first, second], now: now)
    #expect(!timeline.reveals(.body, record: first, at: first.receivedAt, now: now))
    #expect(timeline.reveals(.body, record: first, at: first.receivedAt.addingTimeInterval(0.5), now: now))
    #expect(timeline.nextAfterIdle(at: first.receivedAt.addingTimeInterval(0.8)) == nil)
    #expect(timeline.nextAfterIdle(at: first.receivedAt.addingTimeInterval(1)) == second.receivedAt)
    #expect(timeline.nextAfterIdle(at: second.receivedAt.addingTimeInterval(1)) == nil)
    #expect(!timeline.reveals(.body, record: first, at: now, now: first.expiresAt))
    timeline.removeExpired(now: first.expiresAt)
    #expect(timeline.records.isEmpty)
}

@Test func presentationNeverThresholdsNoulOrInventsConfidence() throws {
    let request = Data(
        #"{"state":{"task":"Review"},"questions":{"risk":{"type":"noul","instructions":["Is this risky?"]},"mode":{"type":"choice","instructions":"Choose","criteria":{"local":null,"delegate":"Independent"}}}}"#
            .utf8)
    let response = Data(
        #"{"answers":{"risk":{"type":"noul","noul":0.6},"mode":{"type":"choice","choice":"local","probabilities":{"local":0.8,"delegate":0.2},"confidence":0.5}}}"#
            .utf8)
    let detail = RequestDetail(summary: sampleRecord(), effectiveRequest: request, upstreamResponse: response)
    let presentation = DecisionPresentation(detail: detail)
    let risk = try #require(presentation.questions.first { $0.id == "risk" })
    #expect(risk.result == nil)
    #expect(risk.confidence == nil)
    #expect(risk.yesProbability == 0.6)
    #expect(presentation.state?["task"]?.stringValue == "Review")
    #expect(presentation.questions.first?.options.count == 2)
}

@Test func exportsEscapeSpreadsheetFormulasAndQuotes() {
    var record = sampleRecord()
    record.sourceName = "=test(\"quoted\")"
    let text = DecisionFormat.csv([record])
    #expect(text.contains("\"'=test(\"\"quoted\"\")\""))
    #expect(DecisionFormat.duration(nil) == "—")
    #expect(DecisionFormat.duration(1234) == "1.23 s")
    #expect(DecisionFormat.probability(0.8) == "80.0%")
}

@Test func scorePresentationPreservesOrdinalLevelsAndExtensions() throws {
    let request = Data(
        #"{"define":{"extra":"preserved"},"state":"fixture","questions":{"rank":{"type":"score","instructions":["Rate","risk"],"criteria":["low","medium","high"]},"yes":{"type":"noul","instructions":"Safe?"}}}"#
            .utf8)
    let response = Data(
        #"{"answers":{"rank":{"type":"score","score":1.7,"confidence":0.4,"probabilities":{"0":0.1,"1":0.1,"2":0.8}},"yes":{"type":"noul","noul":0.2,"confidence":0.8,"choice":"yes"}}}"#
            .utf8)
    var detail = RequestDetail(
        summary: sampleRecord(), receivedRequest: request, effectiveRequest: request, upstreamResponse: response)
    let display = DecisionPresentation(detail: detail)
    let score = try #require(display.questions.first { $0.id == "rank" })
    #expect(score.options.map(\.id) == ["0", "1", "2"])
    #expect(score.options.map(\.definition) == [.string("low"), .string("medium"), .string("high")])
    #expect(score.score == 1.7 && score.confidence == 0.4)
    #expect(score.options.allSatisfy { !$0.selected })
    #expect(display.define?["extra"]?.stringValue == "preserved")
    #expect(display.questions.last?.confidence == nil && display.questions.last?.result == nil)
    detail.summary.status = .invalidResponse
    let invalid = DecisionPresentation(detail: detail)
    #expect(invalid.questions.allSatisfy { $0.confidence == nil && $0.score == nil && $0.yesProbability == nil })
    #expect(invalid.response != nil)
    detail.summary.transport = .mcp
    detail.effectiveRequest = nil
    detail.receivedRequest = try JSONValue.object(["params": .object(["arguments": .decode(request)])]).data()
    #expect(DecisionPresentation(detail: detail).state == .string("fixture"))
}

@Test func playbackRangeExcludesLiveAndExpiredRecordsAndBoundsWork() throws {
    let now = Date()
    var terminal = sampleRecord()
    terminal.receivedAt = now.addingTimeInterval(-10)
    terminal.expiresAt = now.addingTimeInterval(10)
    terminal.timing = RequestTiming(
        bodyReceivedMS: 1, upstreamStartedMS: 2, responseReceivedMS: 3, terminalMS: 4, deliveryFinishedMS: 5)
    terminal.reviewNote = "private"
    terminal.metadata = ["label": "private"]
    terminal.preview = "private"
    var live = terminal
    live.id = UUID()
    live.status = .inFlight
    var expired = terminal
    expired.id = UUID()
    expired.expiresAt = now
    let timeline = try ReplayTimeline(records: [live, expired, terminal], now: now)
    #expect(timeline.records.count == 1)
    #expect(
        timeline.records[0].reviewNote.isEmpty && timeline.records[0].metadata.isEmpty
            && timeline.records[0].preview.isEmpty)
    #expect(timeline.events.map(\.stage) == ReplayStage.allCases)
    #expect(timeline.nextEvent(after: timeline.end) == nil)
    #expect(timeline.previousEvent(before: timeline.start) == nil)
    #expect(!timeline.reveals(.headers, record: live, at: now, now: now))
    #expect(throws: FalconError.self) {
        try ReplayTimeline(records: Array(repeating: terminal, count: 10_001), now: now)
    }
    #expect(try ReplayTimeline(records: [], now: now).duration == 0.001)
}
