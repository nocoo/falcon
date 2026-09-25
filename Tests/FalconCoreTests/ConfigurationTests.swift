import Foundation
import Testing

@testable import FalconCore

@Test func configurationRotatesKeysAndKeepsInflightProfileVersion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "FalconConfigurationTests-\(UUID().uuidString)")
    let marker = UUID()
    let store = try DecisionStore(path: directory.appendingPathComponent("store.sqlite").path, testRunID: marker)
    let vault = CredentialVault.memory()
    let manager = ConfigurationManager(store: store, vault: vault)
    let profile = try await manager.saveProfile(
        UpstreamProfile(name: "Primary", baseURL: "https://api.example.test/base/"), apiKey: "synthetic-one")
    #expect(profile.baseURL == "https://api.example.test/base")
    let issued = try await manager.createSource(name: "IDE", profileID: profile.id, iconID: "codex")
    #expect(issued.source.iconID == "codex")
    #expect(issued.token.hasPrefix("falcon_"))
    #expect(issued.token.count == 50)
    let snapshot = try await manager.acquire(token: issued.token)
    #expect(snapshot.identity.source.iconID == "codex")
    #expect(snapshot.endpoint.absoluteString == "https://api.example.test/base/v1/systemone")
    #expect(snapshot.credential == "synthetic-one")

    var edited = profile
    edited.baseURL = "https://other.example.test/"
    await #expect(throws: (any Error).self) { try await manager.saveProfile(edited, apiKey: nil) }
    let updated = try await manager.saveProfile(edited, apiKey: "synthetic-two")
    #expect(updated.revision == profile.revision + 1)
    #expect(snapshot.profile.baseURL == profile.baseURL)
    #expect(try vault.read(id: profile.credentialID) == "synthetic-one")
    let newSnapshot = try await manager.acquire(token: issued.token)
    #expect(newSnapshot.credential == "synthetic-two")
    #expect(newSnapshot.endpoint.absoluteString == "https://other.example.test/v1/systemone")
    vault.setMemoryRemovalFailure(true)
    await manager.release(snapshot)
    #expect(try vault.read(id: profile.credentialID) == "synthetic-one")
    #expect(try await store.profiles().first?.credentialID == updated.credentialID)
    vault.setMemoryRemovalFailure(false)
    await manager.release(newSnapshot)
    #expect(try vault.read(id: profile.credentialID) == nil)

    let rotated = try await manager.rotateKey(sourceID: issued.source.id)
    await #expect(throws: (any Error).self) { try await manager.authenticate(token: issued.token) }
    #expect(try await manager.authenticate(token: rotated.token).source.id == issued.source.id)
    try await manager.revokeKey(sourceID: issued.source.id)
    await #expect(throws: (any Error).self) { try await manager.authenticate(token: rotated.token) }
    #expect(try await store.testMarkerMatches(marker))
    guard try await store.testMarkerMatches(marker) else {
        throw FalconError("test_marker_mismatch", "Test cleanup refused.")
    }
    try FileManager.default.removeItem(at: directory)
}

@Test func configurationRejectsInvalidTargetsAndDisabledSources() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "FalconConfigurationTests-\(UUID().uuidString)")
    let marker = UUID()
    let store = try DecisionStore(path: directory.appendingPathComponent("store.sqlite").path, testRunID: marker)
    let manager = ConfigurationManager(store: store, vault: .memory())
    for target in [
        "http://api.example.test", "https://user:pass@api.example.test", "https://api.example.test/v1/systemone",
        "https://127.0.0.1:19823",
    ] {
        await #expect(throws: (any Error).self) {
            try await manager.saveProfile(UpstreamProfile(name: "Bad", baseURL: target), apiKey: "synthetic")
        }
    }
    let profile = try await manager.saveProfile(UpstreamProfile(name: "Valid"), apiKey: "synthetic")
    let issued = try await manager.createSource(name: "Agent", profileID: profile.id)
    var source = issued.source
    source.enabled = false
    try await manager.saveSource(source)
    await #expect(throws: (any Error).self) { try await manager.authenticate(token: issued.token) }
    await #expect(throws: (any Error).self) { try await manager.authenticate(token: "falcon_invalid") }
    var disabledProfile = profile
    disabledProfile.enabled = false
    _ = try await manager.saveProfile(disabledProfile, apiKey: nil)
    try await manager.saveSource(source)
    source.enabled = true
    source.archived = true
    try await manager.saveSource(source)
    #expect(try await store.sources().first?.archived == true)
    source.archived = false
    source.enabled = true
    await #expect(throws: (any Error).self) { try await manager.saveSource(source) }
    let liveProfile = try await manager.saveProfile(UpstreamProfile(name: "Other"), apiKey: "synthetic-other")
    source.profileID = liveProfile.id
    try await manager.saveSource(source)
    source.profileID = disabledProfile.id
    await #expect(throws: (any Error).self) { try await manager.saveSource(source) }
    source.profileID = UUID()
    await #expect(throws: (any Error).self) { try await manager.saveSource(source) }
    guard try await store.testMarkerMatches(marker) else {
        throw FalconError("test_marker_mismatch", "Test cleanup refused.")
    }
    try FileManager.default.removeItem(at: directory)
}

@Test func configurationReconcilesOnlyUnreferencedOwnCredentials() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "FalconConfigurationTests-\(UUID().uuidString)")
    let marker = UUID()
    let store = try DecisionStore(path: directory.appendingPathComponent("store.sqlite").path, testRunID: marker)
    let vault = CredentialVault.memory()
    let manager = ConfigurationManager(store: store, vault: vault)
    let profile = try await manager.saveProfile(UpstreamProfile(name: "Current"), apiKey: "synthetic-current")
    let orphan = UUID().uuidString
    try vault.write(id: orphan, value: "synthetic-old")
    let restarted = ConfigurationManager(store: store, vault: vault)
    try await restarted.reconcileCredentials()
    #expect(try vault.read(id: orphan) == nil)
    #expect(try vault.read(id: profile.credentialID) == "synthetic-current")
    guard try await store.testMarkerMatches(marker) else {
        throw FalconError("test_marker_mismatch", "Test cleanup refused.")
    }
    try FileManager.default.removeItem(at: directory)
}
