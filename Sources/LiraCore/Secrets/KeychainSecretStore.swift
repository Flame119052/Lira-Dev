import Foundation
import Security

/// Keychain-backed `SecretStore`. Failures throw; there is no file fallback.
public struct KeychainSecretStore: SecretStore {
    /// Where the item is stored. The data-protection keychain is the only
    /// backend on which `kSecAttrAccessible` / `SecAccessControl` are honored.
    public enum Backend: Sendable, Equatable {
        case dataProtection
        /// Login keychain. Unsigned `swift test` cannot use data-protection;
        /// production (`LiraSecrets` default) must not use this.
        case legacyLogin
    }

    public let backend: Backend

    public init(backend: Backend = .dataProtection) {
        self.backend = backend
    }

    public func store(_ secret: Secret, for account: SecretAccount, access: SecretAccessControl) throws {
        try validate(account)
        let identity = identityQuery(for: account)
        var update = accessAttributes(for: access)
        update[kSecValueData as String] = secret.data
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            let addStatus = add(secret, for: account, access: access)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.keychainFailed(addStatus)
            }
            return
        }
        if updateStatus == errSecParam {
            try replacePreservingIncumbent(secret, for: account, access: access)
            return
        }
        throw SecretStoreError.keychainFailed(updateStatus)
    }

    public func fetch(_ account: SecretAccount) throws -> Secret {
        try validate(account)
        var query = identityQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
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
        let status = SecItemDelete(identityQuery(for: account) as CFDictionary)
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
        access: SecretAccessControl
    ) -> OSStatus {
        var query = identityQuery(for: account)
        query[kSecValueData as String] = secret.data
        query[kSecAttrSynchronizable as String] = false

        switch backend {
        case .dataProtection:
            var error: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                accessibility(for: access),
                [],
                &error
            ) else {
                return errSecParam
            }
            query[kSecAttrAccessControl as String] = accessControl
        case .legacyLogin:
            query[kSecAttrAccessible as String] = accessibility(for: access)
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// `SecItemUpdate` cannot always patch `SecAccessControl`. Fetch the
    /// incumbent, delete, add with the requested ACL, and put the old
    /// value back if the add fails.
    private func replacePreservingIncumbent(
        _ secret: Secret,
        for account: SecretAccount,
        access: SecretAccessControl
    ) throws {
        let incumbent = try? fetch(account)
        let deleteStatus = SecItemDelete(identityQuery(for: account) as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            throw SecretStoreError.keychainFailed(deleteStatus)
        }
        let addStatus = add(secret, for: account, access: access)
        if addStatus == errSecSuccess {
            return
        }
        if let incumbent {
            _ = add(incumbent, for: account, access: access)
        }
        throw SecretStoreError.keychainFailed(addStatus)
    }

    private func accessAttributes(for access: SecretAccessControl) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecAttrSynchronizable as String: false,
        ]
        switch backend {
        case .dataProtection:
            var error: Unmanaged<CFError>?
            if let accessControl = SecAccessControlCreateWithFlags(
                nil,
                accessibility(for: access),
                [],
                &error
            ) {
                attributes[kSecAttrAccessControl as String] = accessControl
            }
        case .legacyLogin:
            attributes[kSecAttrAccessible as String] = accessibility(for: access)
        }
        return attributes
    }

    func identityQuery(for account: SecretAccount) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.service,
            kSecAttrAccount as String: account.account,
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
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
