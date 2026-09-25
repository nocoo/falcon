import Foundation

public final class CredentialVault: @unchecked Sendable {
    private enum Backend {
        case file(URL)
        case memory
    }
    private let backend: Backend
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var memoryRemovalFailure = false

    private init(_ backend: Backend) { self.backend = backend }

    public static func file(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".config/falcon/credentials.json")
    ) throws -> CredentialVault {
        let vault = CredentialVault(.file(url))
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try files.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory
            else {
                throw FalconError(
                    "credential_unavailable", "Falcon credentials require a regular directory.", status: 503)
            }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if files.fileExists(atPath: url.path) {
                guard try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw FalconError(
                        "credential_unavailable", "Falcon credentials require a regular file.", status: 503)
                }
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                _ = try vault.load()
            } else {
                try vault.persist([:])
            }
        } catch { throw FalconError("credential_unavailable", "Unable to open Falcon credentials file.", status: 503) }
        return vault
    }

    public static func memory() -> CredentialVault { CredentialVault(.memory) }

    func setMemoryRemovalFailure(_ enabled: Bool) { lock.withLock { memoryRemovalFailure = enabled } }

    func ownedIDs() throws -> Set<String> { try lock.withLock { Set(try load().keys) } }

    public func read(id: String) throws -> String? {
        guard !id.isEmpty else { return nil }
        return try lock.withLock { try load()[id] }
    }

    public func write(id: String, value: String) throws {
        guard !id.isEmpty, !value.isEmpty else { throw FalconError("invalid_credential", "Credential is required.") }
        try lock.withLock {
            var updated = try load()
            updated[id] = value
            try persist(updated)
        }
    }

    public func remove(id: String) throws {
        guard !id.isEmpty else { return }
        try lock.withLock {
            if case .memory = backend, memoryRemovalFailure {
                throw FalconError("credential_unavailable", "Unable to remove Falcon credential.", status: 503)
            }
            var updated = try load()
            guard updated.removeValue(forKey: id) != nil else { return }
            try persist(updated)
        }
    }

    private func load() throws -> [String: String] {
        switch backend {
        case .memory: return values
        case .file(let url):
            do {
                let stored = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
                guard stored.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
                    throw FalconError("invalid_credential", "Credential is required.")
                }
                return stored
            } catch {
                throw FalconError("credential_unavailable", "Unable to read Falcon credentials file.", status: 503)
            }
        }
    }

    private func persist(_ updated: [String: String]) throws {
        switch backend {
        case .memory: values = updated
        case .file(let url):
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(updated).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                throw FalconError("credential_unavailable", "Unable to save Falcon credentials file.", status: 503)
            }
        }
    }
}
