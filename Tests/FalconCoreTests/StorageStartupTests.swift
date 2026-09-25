import Foundation
import GRDB
import Testing

@testable import FalconCore

@Test(arguments: [false, true]) func storageReopensHistoryWithWAL(existingRollbackFile: Bool) async throws {
    let marker = UUID()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FalconStartupTests-\(marker)")
    let path = directory.appendingPathComponent("history.sqlite").path
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    if existingRollbackFile {
        let database = try DatabaseQueue(path: path)
        try await database.write { connection in
            try connection.execute(sql: "CREATE TABLE _test_marker(run_id TEXT PRIMARY KEY)")
            try connection.execute(sql: "INSERT INTO _test_marker VALUES (?)", arguments: [marker.uuidString])
        }
        try database.close()
    }
    let record = try #require(PreviewData.records().first)
    try await writeStartupHistory(record, path: path, marker: marker)
    let reopened = try DecisionStore(path: path, testRunID: marker)
    let restored = try #require(await reopened.detail(id: record.id))
    #expect(restored.summary.status == record.summary.status)
    #expect(restored.summary.reviewNote == "Survives a restart")
    #expect(restored.receivedRequest == record.receivedRequest)
    #expect(restored.upstreamResponse == record.upstreamResponse)
    #expect(try await reopened.profiles().first?.id == PreviewData.profileID)
    let database = try DatabaseQueue(path: path)
    let configuration = try await database.read { connection in
        (
            try String.fetchOne(connection, sql: "PRAGMA journal_mode"),
            try Int.fetchOne(connection, sql: "PRAGMA auto_vacuum")
        )
    }
    #expect(configuration.0 == "wal")
    if !existingRollbackFile { #expect(configuration.1 == 2) }
    try database.close()
    guard try await reopened.testMarkerMatches(marker) else {
        throw FalconError("test_marker", "Refuse to clean an unmarked fixture.")
    }
    try FileManager.default.removeItem(at: directory)
}

private func writeStartupHistory(_ record: RequestDetail, path: String, marker: UUID) async throws {
    let store = try DecisionStore(path: path, testRunID: marker)
    try await store.saveProfile(UpstreamProfile(id: PreviewData.profileID, name: "Synthetic"))
    try await store.reserve(
        requestID: record.id, requestBytes: record.effectiveRequest?.count ?? 0,
        questionCount: record.summary.questionCount)
    try await store.insert(record)
    try await store.release(requestID: record.id)
    try await store.saveReview(id: record.id, state: .reviewed, note: "Survives a restart")
}
