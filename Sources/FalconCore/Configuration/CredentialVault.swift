import Foundation
import Security

public final class CredentialVault: @unchecked Sendable {
    private enum Backend { case keychain(String), memory }
    private let backend: Backend
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var memoryRemovalFailure = false

    private init(_ backend: Backend) { self.backend = backend }

    public static func keychain(service: String = "ai.hexly.falcon.upstream") -> CredentialVault {
        CredentialVault(.keychain(service))
    }

    public static func memory() -> CredentialVault { CredentialVault(.memory) }

    func setMemoryRemovalFailure(_ enabled: Bool) {
        lock.lock()
        memoryRemovalFailure = enabled
        lock.unlock()
    }

    func ownedIDs() throws -> Set<String> {
        switch backend {
        case .memory:
            lock.lock()
            defer { lock.unlock() }
            return Set(values.keys)
        case .keychain(let service):
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecReturnAttributes as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitAll]
            var items: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &items)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess, let attributes = items as? [[String: Any]] else {
                throw FalconError("credential_unavailable", "Unable to inspect Falcon credentials.", status: 503)
            }
            return Set(attributes.compactMap { $0[kSecAttrAccount as String] as? String })
        }
    }

    public func read(id: String) throws -> String? {
        guard !id.isEmpty else { return nil }
        switch backend {
        case .memory:
            lock.lock()
            defer { lock.unlock() }
            return values[id]
        case .keychain(let service):
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: id,
                                        kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw FalconError("credential_unavailable", "Unable to read Falcon credential.", status: 503)
            }
            return value
        }
    }

    public func write(id: String, value: String) throws {
        guard !id.isEmpty, !value.isEmpty else { throw FalconError("invalid_credential", "Credential is required.") }
        switch backend {
        case .memory:
            lock.lock()
            values[id] = value
            lock.unlock()
        case .keychain(let service):
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: id,
                                        kSecValueData as String: Data(value.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw FalconError("credential_unavailable", "Unable to save Falcon credential.", status: 503)
            }
        }
    }

    public func remove(id: String) throws {
        guard !id.isEmpty else { return }
        switch backend {
        case .memory:
            lock.lock()
            defer { lock.unlock() }
            if memoryRemovalFailure {
                throw FalconError("credential_unavailable", "Unable to remove Falcon credential.", status: 503)
            }
            values.removeValue(forKey: id)
        case .keychain(let service):
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: id]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw FalconError("credential_unavailable", "Unable to remove Falcon credential.", status: 503)
            }
        }
    }
}
