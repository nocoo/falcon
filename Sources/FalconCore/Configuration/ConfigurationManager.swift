import CryptoKit
import Foundation
import Security

public struct IssuedSourceKey: Sendable {
    public let source: AgentSource
    public let key: SourceKey
    public let token: String
    public init(source: AgentSource, key: SourceKey, token: String) {
        self.source = source
        self.key = key
        self.token = token
    }
}

public actor ConfigurationManager {
    private let store: DecisionStore
    private let vault: CredentialVault
    private var activeReferences: [String: Int] = [:]
    private var retiredReferences: Set<String> = []
    private var reconciled = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(store: DecisionStore, vault: CredentialVault) {
        self.store = store
        self.vault = vault
    }

    public func authenticate(token: String) async throws -> SourceIdentity {
        await enter()
        defer { leave() }
        let (identity, _) = try await resolve(token: token)
        return identity
    }

    public func acquire(token: String) async throws -> ExecutionSnapshot {
        await enter()
        defer { leave() }
        try? await reconcileCredentialsLocked()
        let (identity, profile) = try await resolve(token: token)
        guard profile.enabled else { throw FalconError("profile_disabled", "Upstream profile is disabled.", status: 503) }
        guard let secret = try vault.read(id: profile.credentialID) else {
            throw FalconError("credential_unavailable", "Falcon credential is unavailable.", status: 503)
        }
        let endpoint = URL(string: profile.baseURL + "/v1/systemone")!
        activeReferences[profile.credentialID, default: 0] += 1
        return ExecutionSnapshot(identity: identity, profile: profile, endpoint: endpoint, credential: secret)
    }

    public func release(_ snapshot: ExecutionSnapshot) async {
        await enter()
        defer { leave() }
        let id = snapshot.profile.credentialID
        if let count = activeReferences[id], count > 1 { activeReferences[id] = count - 1 }
        else { activeReferences.removeValue(forKey: id) }
        try? await collectRetired()
    }

    public func saveProfile(_ profile: UpstreamProfile, apiKey: String?) async throws -> UpstreamProfile {
        await enter()
        defer { leave() }
        try? await reconcileCredentialsLocked()
        let baseURL = try Self.normalizedURL(profile.baseURL)
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.name.count <= 120, !profile.defaultModel.isEmpty,
              profile.defaultModel.utf8.count <= 200 else {
            throw FalconError("invalid_profile", "Profile name or model is invalid.")
        }
        let current = try await store.profiles().first { $0.id == profile.id }
        let targetChanged = current.map { $0.baseURL != baseURL } ?? true
        if targetChanged && (apiKey?.isEmpty ?? true) {
            throw FalconError("credential_required", "A key is required for a new upstream target.")
        }
        let newID = apiKey == nil ? current?.credentialID : UUID().uuidString
        guard let newID, !newID.isEmpty else { throw FalconError("credential_required", "An upstream key is required.") }
        let newVersion = UpstreamProfile(id: profile.id, name: profile.name, baseURL: baseURL,
                                         defaultModel: profile.defaultModel, revision: (current?.revision ?? 0) + 1,
                                         credentialID: newID, enabled: profile.enabled)
        if let apiKey { try vault.write(id: newID, value: apiKey) }
        do {
            try await store.saveProfile(newVersion)
        } catch {
            if apiKey != nil { try? vault.remove(id: newID) }
            throw error
        }
        if let current, current.credentialID != newID {
            retiredReferences.insert(current.credentialID)
            try? await collectRetired()
        }
        return newVersion
    }

    public func createSource(name: String, profileID: UUID) async throws -> IssuedSourceKey {
        await enter()
        defer { leave() }
        guard try await store.profiles().contains(where: { $0.id == profileID && $0.enabled }) else {
            throw FalconError("profile_missing", "Enabled upstream profile is required.")
        }
        let source = AgentSource(name: name, profileID: profileID)
        let issued = try Self.generateKey(for: source)
        try await store.createSourceWithKey(source, key: issued.key)
        return issued
    }

    public func rotateKey(sourceID: UUID) async throws -> IssuedSourceKey {
        await enter()
        defer { leave() }
        guard let source = try await store.sources().first(where: { $0.id == sourceID }),
              source.enabled, !source.archived else {
            throw FalconError("source_missing", "Active source is required.")
        }
        let issued = try Self.generateKey(for: source)
        try await store.replaceKey(issued.key)
        return issued
    }

    public func revokeKey(sourceID: UUID) async throws {
        await enter()
        defer { leave() }
        try await store.revokeKey(sourceID: sourceID)
    }

    public func saveSource(_ source: AgentSource) async throws {
        await enter()
        defer { leave() }
        guard let profile = try await store.profiles().first(where: { $0.id == source.profileID }) else {
            throw FalconError("profile_missing", "Upstream profile is required.")
        }
        guard !source.enabled || source.archived || profile.enabled else {
            throw FalconError("profile_disabled", "Enabled upstream profile is required.")
        }
        try await store.saveSource(source)
    }

    public func reconcileCredentials() async throws {
        await enter()
        defer { leave() }
        try await reconcileCredentialsLocked()
    }

    private func resolve(token: String) async throws -> (SourceIdentity, UpstreamProfile) {
        guard token.hasPrefix("falcon_"), token.utf8.count == 50 else {
            throw FalconError("unauthorized", "Invalid source key.", status: 401)
        }
        let digest = Data(SHA256.hash(data: Data(token.utf8)))
        guard let pair = try await store.configurationSnapshot(tokenDigest: digest) else {
            throw FalconError("unauthorized", "Invalid source key.", status: 401)
        }
        guard pair.0.source.enabled, !pair.0.source.archived else {
            throw FalconError("source_disabled", "Source is disabled.", status: 403)
        }
        return pair
    }

    private static func generateKey(for source: AgentSource) throws -> IssuedSourceKey {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw FalconError("random_unavailable", "Unable to generate source key.") }
        let token = "falcon_" + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let key = SourceKey(sourceID: source.id, digest: Data(SHA256.hash(data: Data(token.utf8))),
                            suffix: String(token.suffix(4)))
        return IssuedSourceKey(source: source, key: key, token: token)
    }

    private func collectRetired() async throws {
        let current = Set(try await store.profiles().map(\.credentialID))
        for id in retiredReferences where activeReferences[id] == nil && !current.contains(id) {
            try vault.remove(id: id)
            retiredReferences.remove(id)
        }
    }

    private func reconcileCredentialsLocked() async throws {
        guard !reconciled else { return }
        let current = Set(try await store.profiles().map(\.credentialID))
        for id in try vault.ownedIDs() where UUID(uuidString: id) != nil && !current.contains(id) && activeReferences[id] == nil {
            try vault.remove(id: id)
        }
        reconciled = true
    }

    private static func normalizedURL(_ raw: String) throws -> String {
        guard var parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              !["localhost", "127.0.0.1", "0.0.0.0"].contains(host.lowercased()) else {
            throw FalconError("invalid_upstream_url", "A valid HTTPS upstream root is required.")
        }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.lowercased().hasSuffix("/v1/systemone") else {
            throw FalconError("invalid_upstream_url", "Enter the API root, not the inference endpoint.")
        }
        parts.percentEncodedPath = path
        let value = parts.string ?? ""
        guard !value.isEmpty else { throw FalconError("invalid_upstream_url", "A valid HTTPS upstream root is required.") }
        return value
    }

    private func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }

    private func leave() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
