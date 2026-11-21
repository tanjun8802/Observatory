import Foundation
import Security

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

    func read(_ service: Credential) throws -> String? {
        var query = item(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
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
        } else {
            if try read(service) == trimmed { return }
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
