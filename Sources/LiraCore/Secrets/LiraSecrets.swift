import Foundation

/// The provider/connector credential API. Future tickets (#57, #59, #71)
/// store keys here — they do not invent a parallel secret store.
public struct LiraSecrets: Sendable {
    private let store: any SecretStore

    public init(store: any SecretStore = KeychainSecretStore()) {
        self.store = store
    }

    public func store(_ secret: Secret, purpose: SecretPurpose, name: String) throws {
        try store.store(
            secret,
            for: account(purpose: purpose, name: name),
            access: .whenUnlockedThisDeviceOnly
        )
    }

    public func fetch(purpose: SecretPurpose, name: String) throws -> Secret {
        try store.fetch(account(purpose: purpose, name: name))
    }

    public func delete(purpose: SecretPurpose, name: String) throws {
        try store.delete(account(purpose: purpose, name: name))
    }

    private func account(purpose: SecretPurpose, name: String) -> SecretAccount {
        SecretAccount(service: "lira.\(purpose.rawValue)", account: name)
    }
}
