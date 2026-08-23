import Foundation

/// A secret value. Never print this — `description` is always redacted.
public struct Secret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public init(utf8: String) {
        self.data = Data(utf8.utf8)
    }

    public var description: String {
        "<redacted \(data.count) bytes>"
    }

    public var debugDescription: String {
        description
    }
}

public struct SecretAccount: Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum SecretAccessControl: Sendable, Equatable {
    /// Available only while this Mac is unlocked; does not roam via iCloud.
    case whenUnlockedThisDeviceOnly
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case invalidAccount
    case notFound
    case accessControlFailed
    case keychainFailed(OSStatus)
}

/// Named purposes the ticket listed. Provider (#57), Activepieces (#71),
/// Tailscale, and the resident/cloud model keys all go through this — never
/// a file path.
public enum SecretPurpose: String, Sendable, CaseIterable {
    case modelProvider
    case cloudProvider
    case activepieces
    case tailscale
}

public protocol SecretStore: Sendable {
    func store(_ secret: Secret, for account: SecretAccount, access: SecretAccessControl) throws
    func fetch(_ account: SecretAccount) throws -> Secret
    func delete(_ account: SecretAccount) throws
}
