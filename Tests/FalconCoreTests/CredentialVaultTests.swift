import Foundation
import Testing

@testable import FalconCore

private struct CredentialFileFixture {
    let marker = UUID()
    let directory: URL
    let store: DecisionStore
    var file: URL { directory.appendingPathComponent("config/credentials.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FalconCredentialTests-\(marker)")
        store = try DecisionStore(path: directory.appendingPathComponent("store.sqlite").path, testRunID: marker)
    }

    func cleanup() async throws {
        guard try await store.testMarkerMatches(marker) else {
            throw FalconError("test_marker_mismatch", "Test cleanup refused.")
        }
        try FileManager.default.removeItem(at: directory)
    }
}

@Test func credentialFilePersistsAndRestrictsPermissions() async throws {
    let fixture = try CredentialFileFixture()
    let vault = try CredentialVault.file(at: fixture.file)
    #expect(try vault.ownedIDs().isEmpty)
    try vault.write(id: "first", value: "synthetic-one")
    try vault.write(id: "second", value: "synthetic-two")
    let reopened = try CredentialVault.file(at: fixture.file)
    #expect(try reopened.read(id: "first") == "synthetic-one")
    #expect(try reopened.ownedIDs() == ["first", "second"])
    try reopened.write(id: "first", value: "synthetic-updated")
    #expect(try vault.read(id: "first") == "synthetic-updated")
    try vault.remove(id: "second")
    try vault.remove(id: "missing")
    try vault.remove(id: "")
    #expect(try reopened.read(id: "second") == nil)
    #expect(try reopened.read(id: "") == nil)
    #expect(throws: FalconError.self) { try vault.write(id: "", value: "synthetic") }
    #expect(throws: FalconError.self) { try vault.write(id: "first", value: "") }
    let contents = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixture.file))
    #expect(contents == ["first": "synthetic-updated"])
    let files = FileManager.default
    let parent = fixture.file.deletingLastPathComponent()
    #expect(try files.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? Int == 0o600)
    #expect(try files.attributesOfItem(atPath: parent.path)[.posixPermissions] as? Int == 0o700)
    try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.path)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
    _ = try CredentialVault.file(at: fixture.file)
    #expect(try files.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? Int == 0o600)
    #expect(try files.attributesOfItem(atPath: parent.path)[.posixPermissions] as? Int == 0o700)
    try await fixture.cleanup()
}

@Test func credentialFileSerializesConcurrentUpdates() async throws {
    let fixture = try CredentialFileFixture()
    let vault = try CredentialVault.file(at: fixture.file)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<32 { group.addTask { try vault.write(id: "key-\(index)", value: "synthetic-\(index)") } }
        try await group.waitForAll()
    }
    let reopened = try CredentialVault.file(at: fixture.file)
    #expect(try reopened.ownedIDs().count == 32)
    for index in 0..<32 { #expect(try reopened.read(id: "key-\(index)") == "synthetic-\(index)") }
    try await fixture.cleanup()
}

@Test(arguments: ["{synthetic-malformed", "{\"key\":42}", "{\"key\":\"\"}", "{\"\":\"synthetic\"}"])
func credentialFileRejectsCorruptionWithoutOverwriting(_ text: String) async throws {
    let fixture = try CredentialFileFixture()
    let vault = try CredentialVault.file(at: fixture.file)
    let invalid = Data(text.utf8)
    try invalid.write(to: fixture.file)
    let failure = FalconError("credential_unavailable", "Unable to read Falcon credentials file.", status: 503)
    #expect(throws: failure) { try vault.read(id: "key") }
    #expect(throws: failure) { try vault.write(id: "new", value: "synthetic") }
    #expect(throws: failure) { try vault.remove(id: "key") }
    #expect(throws: failure) { try vault.ownedIDs() }
    #expect(throws: FalconError.self) { try CredentialVault.file(at: fixture.file) }
    #expect(try Data(contentsOf: fixture.file) == invalid)
    try FileManager.default.removeItem(at: fixture.file)
    #expect(throws: failure) { try vault.read(id: "key") }
    #expect(throws: failure) { try vault.write(id: "new", value: "synthetic") }
    #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    try await fixture.cleanup()
}

@Test func credentialFileRefusesSymbolicLinks() async throws {
    let fixture = try CredentialFileFixture()
    let files = FileManager.default
    let target = fixture.directory.appendingPathComponent("other.json")
    let original = Data("{\"other\":\"synthetic\"}".utf8)
    try original.write(to: target)
    try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    try files.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.createSymbolicLink(at: fixture.file, withDestinationURL: target)
    #expect(throws: FalconError.self) { try CredentialVault.file(at: fixture.file) }
    #expect(try Data(contentsOf: target) == original)
    #expect(try files.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o644)
    try await fixture.cleanup()
}

@Test func configurationFileWriteFailureKeepsActiveProfile() async throws {
    let fixture = try CredentialFileFixture()
    let vault = try CredentialVault.file(at: fixture.file)
    let manager = ConfigurationManager(store: fixture.store, vault: vault)
    let profile = try await manager.saveProfile(UpstreamProfile(name: "Primary"), apiKey: "synthetic-original")
    let issued = try await manager.createSource(name: "Agent", profileID: profile.id)
    let original = try Data(contentsOf: fixture.file)
    let parent = fixture.file.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
    await #expect(throws: FalconError.self) { try await manager.saveProfile(profile, apiKey: "synthetic-replacement") }
    #expect(try Data(contentsOf: fixture.file) == original)
    #expect(try await fixture.store.profiles().first == profile)
    let snapshot = try await manager.acquire(token: issued.token)
    #expect(snapshot.credential == "synthetic-original")
    await manager.release(snapshot)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    try await fixture.cleanup()
}

@Test func configurationFileCredentialsRotateAndSurviveRestart() async throws {
    let fixture = try CredentialFileFixture()
    let vault = try CredentialVault.file(at: fixture.file)
    let manager = ConfigurationManager(store: fixture.store, vault: vault)
    let profile = try await manager.saveProfile(UpstreamProfile(name: "Primary"), apiKey: "synthetic-first")
    let issued = try await manager.createSource(name: "Agent", profileID: profile.id)
    let oldSnapshot = try await manager.acquire(token: issued.token)
    var edited = profile
    edited.baseURL = "https://other.example.test"
    let updated = try await manager.saveProfile(edited, apiKey: "synthetic-second")
    #expect(try vault.read(id: profile.credentialID) == "synthetic-first")
    #expect(oldSnapshot.credential == "synthetic-first")
    await manager.release(oldSnapshot)
    #expect(try vault.read(id: profile.credentialID) == nil)
    let orphan = UUID().uuidString
    try vault.write(id: orphan, value: "synthetic-orphan")
    let reopened = try CredentialVault.file(at: fixture.file)
    let restarted = ConfigurationManager(store: fixture.store, vault: reopened)
    try await restarted.reconcileCredentials()
    #expect(try reopened.ownedIDs() == [updated.credentialID])
    let snapshot = try await restarted.acquire(token: issued.token)
    #expect(snapshot.credential == "synthetic-second")
    #expect(snapshot.endpoint.absoluteString == "https://other.example.test/v1/systemone")
    #expect(snapshot.profile.revision == profile.revision + 1)
    #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains(issued.token) == false)
    await restarted.release(snapshot)
    try await fixture.cleanup()
}
