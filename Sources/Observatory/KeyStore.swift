import Foundation
import Security
import LocalAuthentication

actor KeyStore {
    static let shared = KeyStore()

    private func item(_ service: Credential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.observatory.dashboard.providers",
            kSecAttrAccount as String: service.rawValue
        ]
    }

    func hasKey(_ service: Credential) throws -> Bool {
        var query = item(service)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw keychainError(status) }
        return true
    }

    func read(_ service: Credential, interactive: Bool = true) throws -> String? {
        var query = item(service)
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        // Existing Observatory keys live in the file-based login keychain. Its ACL
        // prompt is independent of LAContext. Keep all accesses serialized on this
        // actor and restore the process setting before returning or suspending.
        var priorInteraction: DarwinBoolean = false
        if !interactive {
            let prior = SecKeychainGetUserInteractionAllowed(&priorInteraction)
            guard prior == errSecSuccess else { throw keychainError(prior) }
            let disabled = SecKeychainSetUserInteractionAllowed(false)
            guard disabled == errSecSuccess else { throw keychainError(disabled) }
        }
        defer {
            if !interactive { SecKeychainSetUserInteractionAllowed(priorInteraction.boolValue) }
        }
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw keychainError(errSecDecode)
        }
        return value
    }

    func write(_ value: String, for service: Credential) throws {
        let query = item(service)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw keychainError(status) }
        } else if try read(service) != trimmed {
            let attributes = [kSecValueData as String: Data(trimmed.utf8)]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw keychainError(status) }
        }
        NotificationCenter.default.post(name: .providerCredentialsChanged, object: service.rawValue)
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain is unavailable."
        ])
    }
}

extension Notification.Name {
    static let providerCredentialsChanged = Notification.Name("Observatory.providerCredentialsChanged")
}

/// A refresh of several tiles can share one authorization. Release the result as soon
/// as the Keychain call finishes so future refreshes observe key changes and revocation.
@MainActor
final class ProviderKeyReader {
    private struct Request: Hashable {
        let service: Credential
        let interactive: Bool
    }
    private let readKey: (Credential, Bool) async throws -> String?
    private var pending: [Request: Task<String?, Error>] = [:]

    init(readKey: @escaping (Credential, Bool) async throws -> String?) {
        self.readKey = readKey
    }

    func read(_ service: Credential, interactive: Bool) async throws -> String? {
        let request = Request(service: service, interactive: interactive)
        if let active = pending[request] { return try await active.value }
        let task = Task { try await readKey(service, interactive) }
        pending[request] = task
        defer { pending.removeValue(forKey: request) }
        return try await task.value
    }
}
