import Foundation
import GRDB
import Testing

@testable import FalconCore

@MainActor @Test func previewShutdownStopsReadsBeforeRemovingFiles() async throws {
    let marker = UUID()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FalconShutdownTests-\(marker)")
    let store = try DecisionStore(path: directory.appendingPathComponent("history.sqlite").path, testRunID: marker)
    try await store.saveProfile(UpstreamProfile(name: "Synthetic"))
    let model = WorkspaceModel(store: store)
    let observation = Task { await model.observeChanges() }
    await model.refresh(reset: true)
    model.stop()
    observation.cancel()
    await observation.value
    guard try await store.testMarkerMatches(marker) else { throw FalconError("test_marker", "Invalid fixture.") }
    try await store.close()
    try FileManager.default.removeItem(at: directory)
    await model.setActive(true)
    await model.refresh(reset: true)
    await model.observeChanges()
    #expect(model.errorMessage == nil && !model.isActive && !model.isLoading)
}

@Test func storageCloseReleasesItsLockAndPreservesHistory() async throws {
    let marker = UUID()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FalconCloseTests-\(marker)")
    let path = directory.appendingPathComponent("history.sqlite").path
    let record = try #require(PreviewData.records().first)
    try await writeStartupHistory(record, path: path, marker: marker)
    let original = try DecisionStore(path: path, testRunID: marker)
    try await original.close()
    let reopened = try DecisionStore(path: path, testRunID: marker)
    try await original.close()
    #expect(throws: FalconError.self) { try DecisionStore(path: path, testRunID: marker) }
    let restored = try #require(await reopened.detail(id: record.id))
    #expect(restored.summary.reviewNote == "Survives a restart")
    #expect(restored.receivedRequest == record.receivedRequest && restored.upstreamResponse == record.upstreamResponse)
    guard try await reopened.testMarkerMatches(marker) else { throw FalconError("test_marker", "Invalid fixture.") }
    try await reopened.close()
    try FileManager.default.removeItem(at: directory)
}

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
    try await reopened.close()
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

@Test func sourceIconsPersistWithExistingKeysAcrossReopen() async throws {
    let marker = UUID()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FalconIconsTests-\(marker)")
    let path = directory.appendingPathComponent("history.sqlite").path
    let profile = UpstreamProfile(name: "Synthetic")
    let keyless = AgentSource(name: "Existing", profileID: profile.id)
    let existingKey = SourceKey(sourceID: keyless.id, digest: Data(repeating: 8, count: 32), suffix: "old!")
    var decorated = AgentSource(name: "New", profileID: profile.id, iconID: "codex")
    let key = SourceKey(sourceID: decorated.id, digest: Data(repeating: 7, count: 32), suffix: "test")
    do {
        let store = try DecisionStore(path: path, testRunID: marker)
        try await store.saveProfile(profile)
        try await store.createSourceWithKey(keyless, key: existingKey)
        try await store.createSourceWithKey(decorated, key: key)
        let sources = try await store.sources()
        #expect(sources.first { $0.id == keyless.id }?.iconID == nil)
        let existing = try #require(await store.configurationSnapshot(tokenDigest: existingKey.digest))
        #expect(existing.0.source.iconID == nil)
        decorated.iconID = "grok"
        try await store.saveSource(decorated)
        let identity = try #require(await store.configurationSnapshot(tokenDigest: key.digest))
        #expect(identity.0.source.iconID == "grok")
    }
    let reopened = try DecisionStore(path: path, testRunID: marker)
    let restoredSources = try await reopened.sources()
    #expect(restoredSources.first { $0.id == keyless.id }?.iconID == nil)
    #expect(restoredSources.first { $0.id == decorated.id }?.iconID == "grok")
    let restoredExisting = try #require(await reopened.configurationSnapshot(tokenDigest: existingKey.digest))
    #expect(restoredExisting.0.source.iconID == nil)
    let identity = try #require(await reopened.configurationSnapshot(tokenDigest: key.digest))
    #expect(identity.0.source.iconID == "grok")
    decorated.iconID = nil
    try await reopened.saveSource(decorated)
    let cleared = try #require(await reopened.configurationSnapshot(tokenDigest: key.digest))
    #expect(cleared.0.source.iconID == nil)
    guard try await reopened.testMarkerMatches(marker) else {
        throw FalconError("test_marker", "Refuse to clean an unmarked fixture.")
    }
    try await reopened.close()
    try FileManager.default.removeItem(at: directory)
}
