import Foundation
import Security
import XCTest
@testable import LiraCore

final class KeychainSecretsTests: XCTestCase {
    private var accounts: [SecretAccount] = []

    override func tearDown() {
        let store = KeychainSecretStore()
        for account in accounts {
            try? store.delete(account)
        }
        accounts.removeAll()
        super.tearDown()
    }

    func testStoreFetchDeleteRoundTrip() throws {
        let store = KeychainSecretStore()
        let account = uniqueAccount(purpose: "round-trip")
        let secret = Secret(utf8: "sk-test-not-a-real-key")

        try store.store(secret, for: account, access: .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(try store.fetch(account), secret)

        try store.delete(account)
        XCTAssertThrowsError(try store.fetch(account)) { error in
            XCTAssertEqual(error as? SecretStoreError, .notFound)
        }
    }

    func testStoredItemUsesThisDeviceOnlyAccessControl() throws {
        let store = KeychainSecretStore()
        let account = uniqueAccount(purpose: "acl")
        try store.store(Secret(utf8: "token"), for: account, access: .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(try store.fetch(account), Secret(utf8: "token"))

        let entitled = store.writeQuery(
            secret: Secret(utf8: "token"),
            account: account,
            access: .whenUnlockedThisDeviceOnly,
            useAccessControlObject: true
        )
        XCTAssertNotNil(entitled[kSecAttrAccessControl as String])

        let fallback = store.writeQuery(
            secret: Secret(utf8: "token"),
            account: account,
            access: .whenUnlockedThisDeviceOnly,
            useAccessControlObject: false
        )
        XCTAssertEqual(
            fallback[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(fallback[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testFailedStoreDoesNotWriteAPlaintextFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = KeychainSecretStore()
        let account = SecretAccount(service: "", account: "")
        XCTAssertThrowsError(
            try store.store(Secret(utf8: "leaked"), for: account, access: .whenUnlockedThisDeviceOnly)
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
        let store = KeychainSecretStore()
        let secrets = LiraSecrets(store: store)
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
            try? KeychainSecretStore().delete(account)
        }
        return account
    }
}
