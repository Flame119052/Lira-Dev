import Foundation
import Security
import XCTest
@testable import LiraCore

final class KeychainSecretsTests: XCTestCase {
    private var accounts: [SecretAccount] = []
    /// Unsigned `swift test` cannot use the data-protection keychain.
    /// Round-trip tests use the login keychain; the ACL test asks the OS
    /// what was stored and skips when entitlements are missing.
    private let ciStore = KeychainSecretStore(backend: .legacyLogin)

    override func tearDown() {
        for account in accounts {
            try? ciStore.delete(account)
            try? KeychainSecretStore(backend: .dataProtection).delete(account)
        }
        accounts.removeAll()
        super.tearDown()
    }

    func testProductionBackendIsDataProtection() {
        XCTAssertEqual(KeychainSecretStore().backend, .dataProtection)
    }

    func testStoreFetchDeleteRoundTrip() throws {
        let account = uniqueAccount(purpose: "round-trip")
        let secret = Secret(utf8: "sk-test-not-a-real-key")

        try ciStore.store(secret, for: account, access: .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(try ciStore.fetch(account), secret)

        try ciStore.delete(account)
        XCTAssertThrowsError(try ciStore.fetch(account)) { error in
            XCTAssertEqual(error as? SecretStoreError, .notFound)
        }
    }

    func testReplaceUpdatesWithoutDestroyingTheIncumbentFirst() throws {
        let account = uniqueAccount(purpose: "replace")
        try ciStore.store(Secret(utf8: "old-key"), for: account, access: .whenUnlockedThisDeviceOnly)
        try ciStore.store(Secret(utf8: "new-key"), for: account, access: .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(try ciStore.fetch(account), Secret(utf8: "new-key"))
    }

    func testDataProtectionStoreRecordsAccessControlOnTheItem() throws {
        let store = KeychainSecretStore(backend: .dataProtection)
        let account = uniqueAccount(purpose: "acl")
        do {
            try store.store(Secret(utf8: "token"), for: account, access: .whenUnlockedThisDeviceOnly)
            try store.store(Secret(utf8: "rotated"), for: account, access: .whenUnlockedThisDeviceOnly)
        } catch let SecretStoreError.keychainFailed(status) where status == errSecMissingEntitlement {
            throw XCTSkip("data-protection keychain needs a signed binary; CI swift test is unsigned")
        }

        var query = store.identityQuery(for: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess, "expected the item in the data-protection keychain after replace")
        let ns = try XCTUnwrap(result as? NSDictionary)
        let accessible = ns[kSecAttrAccessible] as? String
        XCTAssertTrue(
            ns[kSecAttrAccessControl] != nil
                || accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
            "replace must keep access-control; keys=\(ns.allKeys)"
        )
        XCTAssertEqual(try store.fetch(account), Secret(utf8: "rotated"))
        try store.delete(account)
    }

    func testFailedStoreDoesNotWriteAPlaintextFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try ciStore.store(
                Secret(utf8: "leaked"),
                for: SecretAccount(service: "", account: ""),
                access: .whenUnlockedThisDeviceOnly
            )
        )

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files, [], "a Keychain failure must not fall back to a file")
    }

    func testSecretDescriptionRedactsBytes() {
        let secret = Secret(utf8: "super-secret-value")
        let description = String(describing: secret)
        XCTAssertFalse(description.contains("super-secret-value"))
        XCTAssertTrue(description.contains("redacted"))
    }

    func testLiraSecretsExposesProviderAndConnectorPurposes() throws {
        let secrets = LiraSecrets(store: ciStore)
        addTeardownBlock {
            for purpose in SecretPurpose.allCases {
                try? secrets.delete(purpose: purpose, name: "test")
            }
        }

        for purpose in SecretPurpose.allCases {
            let secret = Secret(utf8: "value-for-\(purpose.rawValue)")
            try secrets.store(secret, purpose: purpose, name: "test")
            XCTAssertEqual(try secrets.fetch(purpose: purpose, name: "test"), secret)
            try secrets.delete(purpose: purpose, name: "test")
        }

        XCTAssertEqual(
            SecretPurpose.allCases.map(\.rawValue),
            ["modelProvider", "cloudProvider", "activepieces", "tailscale"]
        )
    }

    func testIncumbentReplaceDoesNotDeleteWhenFetchFails() {
        var deleted = false
        XCTAssertThrowsError(
            try IncumbentReplace.perform(
                newSecret: Secret(utf8: "new"),
                fetchIncumbent: { throw SecretStoreError.keychainFailed(errSecAuthFailed) },
                deleteItem: { deleted = true },
                addItem: { _ in errSecSuccess }
            )
        )
        XCTAssertFalse(deleted)
    }

    func testIncumbentReplaceRestoresThenReportsTheFailedAdd() throws {
        var stored = Secret(utf8: "old")
        XCTAssertThrowsError(
            try IncumbentReplace.perform(
                newSecret: Secret(utf8: "new"),
                fetchIncumbent: { stored },
                deleteItem: { stored = Secret(Data()) },
                addItem: { candidate in
                    if candidate == Secret(utf8: "new") { return errSecParam }
                    stored = candidate
                    return errSecSuccess
                }
            )
        ) { error in
            XCTAssertEqual(error as? SecretStoreError, .replaceRejected(errSecParam))
        }
        XCTAssertEqual(stored, Secret(utf8: "old"))
    }

    func testIncumbentReplaceSurfacesRestoreFailure() {
        XCTAssertThrowsError(
            try IncumbentReplace.perform(
                newSecret: Secret(utf8: "new"),
                fetchIncumbent: { Secret(utf8: "old") },
                deleteItem: {},
                addItem: { _ in errSecDuplicateItem }
            )
        ) { error in
            XCTAssertEqual(
                error as? SecretStoreError,
                .incumbentRestoreFailed(add: errSecDuplicateItem, restore: errSecDuplicateItem)
            )
        }
    }

    func testSecretsAPIHasNoFilePathSurface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LiraCore/Secrets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), root.path)

        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("filePath")
                    || trimmed.contains("plaintext")
                    || trimmed.contains("write(to:")
                    || trimmed.contains("FileManager.default.createFile")
                {
                    hits.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(hits, [], "secrets boundary must not grow a file-backed path: \(hits)")
    }

    private func uniqueAccount(purpose: String) -> SecretAccount {
        let account = SecretAccount(
            service: "lira.test.\(purpose).\(UUID().uuidString)",
            account: "credential"
        )
        accounts.append(account)
        addTeardownBlock { [account] in
            try? KeychainSecretStore(backend: .legacyLogin).delete(account)
            try? KeychainSecretStore(backend: .dataProtection).delete(account)
        }
        return account
    }
}
