import Foundation
import Security

/// Keychain-backed `SecretStore`. Failures throw; there is no file fallback.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func store(_ secret: Secret, for account: SecretAccount, access: SecretAccessControl) throws {
        try validate(account)
        try? delete(account)

        let status = add(secret, for: account, access: access, useAccessControlObject: true)
        if status == errSecMissingEntitlement {
            // Unsigned `swift test` (and similar) cannot attach SecAccessControl.
            // Retry with the same accessibility class; still Keychain, never a file.
            let retry = add(secret, for: account, access: access, useAccessControlObject: false)
            guard retry == errSecSuccess else {
                throw SecretStoreError.keychainFailed(retry)
            }
            return
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailed(status)
        }
    }

    public func fetch(_ account: SecretAccount) throws -> Secret {
        try validate(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.service,
            kSecAttrAccount as String: account.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw SecretStoreError.notFound
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError.keychainFailed(status)
        }
        return Secret(data)
    }

    public func delete(_ account: SecretAccount) throws {
        try validate(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.service,
            kSecAttrAccount as String: account.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw SecretStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailed(status)
        }
    }

    private func add(
        _ secret: Secret,
        for account: SecretAccount,
        access: SecretAccessControl,
        useAccessControlObject: Bool
    ) -> OSStatus {
        let query = writeQuery(
            secret: secret,
            account: account,
            access: access,
            useAccessControlObject: useAccessControlObject
        )
        if useAccessControlObject, query[kSecAttrAccessControl as String] == nil {
            return errSecParam
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Visible to tests: the exact attributes written to Keychain. macOS's
    /// login keychain does not echo `kSecAttrAccessible` on `SecItemCopyMatching`,
    /// so the policy is asserted here against the Security.framework constant.
    func writeQuery(
        secret: Secret,
        account: SecretAccount,
        access: SecretAccessControl,
        useAccessControlObject: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.service,
            kSecAttrAccount as String: account.account,
            kSecValueData as String: secret.data,
            kSecAttrSynchronizable as String: false,
        ]
        if useAccessControlObject {
            var error: Unmanaged<CFError>?
            if let accessControl = SecAccessControlCreateWithFlags(
                nil,
                accessibility(for: access),
                [],
                &error
            ) {
                query[kSecAttrAccessControl as String] = accessControl
            }
        } else {
            query[kSecAttrAccessible as String] = accessibility(for: access)
        }
        return query
    }

    private func validate(_ account: SecretAccount) throws {
        if account.service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || account.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw SecretStoreError.invalidAccount
        }
    }

    private func accessibility(for access: SecretAccessControl) -> CFString {
        switch access {
        case .whenUnlockedThisDeviceOnly:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}
