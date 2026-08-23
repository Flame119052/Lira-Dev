import Darwin
import Foundation
import Security

/// Decides whether an observed peer credential is allowed on a channel.
/// Unix sockets supply `PeerCredential.processID` / `.auditToken`; an XPC
/// transport (#47) supplies `.auditToken` from the connection's audit token.
/// Versioning, invalidation, and ledger recording live outside this type
/// so both transports share them.
public protocol PeerAuthenticator: Sendable {
    func authenticate(
        credential: PeerCredential,
        expected: PeerIdentity,
        claimed: ComponentID?
    ) throws -> AuthenticatedPeer
}

/// Production authenticator: pid allowlist, parent-pid check, and optional
/// codesign requirement. Fail-closed when a configured check cannot run.
/// A nil requirement is intentional for ad-hoc / same-bundle children (#75).
public struct DarwinPeerAuthenticator: PeerAuthenticator {
    public init() {}

    public func authenticate(
        credential: PeerCredential,
        expected: PeerIdentity,
        claimed: ComponentID?
    ) throws -> AuthenticatedPeer {
        if !expected.hasVerificationRule {
            throw IPCError.peerRejected(reason: .noVerificationConfigured)
        }
        guard let claimed, claimed == expected.component else {
            throw IPCError.peerRejected(reason: .componentMismatch)
        }
        if let allowed = expected.allowedPeerPIDs, !allowed.contains(credential.pid) {
            throw IPCError.peerRejected(reason: .pidNotAllowed)
        }
        if let parent = expected.allowedParentPID {
            let isParent = credential.pid == parent
            let isChild = ProcessIdentity.parentPID(of: credential.pid) == parent
            if !isParent && !isChild {
                throw IPCError.peerRejected(reason: .parentPIDMismatch)
            }
        }
        if let requirement = expected.codeSigningRequirement {
            try Self.verifyCodesign(credential: credential, requirement: requirement)
        }
        return AuthenticatedPeer(component: claimed, pid: credential.pid)
    }

    private static func verifyCodesign(credential: PeerCredential, requirement: String) throws {
        var code: SecCode?
        let attributes: CFDictionary
        switch credential {
        case .auditToken(let token):
            var raw = token.raw
            let data = Data(bytes: &raw, count: MemoryLayout<audit_token_t>.size)
            attributes = [kSecGuestAttributeAudit: data] as CFDictionary
        case .processID(let pid):
            attributes = [kSecGuestAttributePid: pid] as CFDictionary
        }
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard copyStatus == errSecSuccess, let code else {
            throw IPCError.peerRejected(reason: .codesignInvalid)
        }
        var secRequirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirement as CFString, [], &secRequirement)
        guard reqStatus == errSecSuccess, let secRequirement else {
            throw IPCError.peerRejected(reason: .codesignInvalid)
        }
        let validity = SecCodeCheckValidity(code, [], secRequirement)
        guard validity == errSecSuccess else {
            throw IPCError.peerRejected(reason: .codesignInvalid)
        }
    }
}

/// Test / in-process authenticator: the peer's actual component is known
/// to the caller (not taken from the handshake). Used to prove that
/// credentials for component A do not open channel B.
public struct AllowlistPeerAuthenticator: PeerAuthenticator {
    public let actualComponent: ComponentID

    public init(actualComponent: ComponentID) {
        self.actualComponent = actualComponent
    }

    public func authenticate(
        credential: PeerCredential,
        expected: PeerIdentity,
        claimed: ComponentID?
    ) throws -> AuthenticatedPeer {
        if let allowed = expected.allowedPeerPIDs, !allowed.contains(credential.pid) {
            throw IPCError.peerRejected(reason: .pidNotAllowed)
        }
        guard actualComponent == expected.component else {
            throw IPCError.peerRejected(reason: .componentMismatch)
        }
        guard let claimed, claimed == expected.component else {
            throw IPCError.peerRejected(reason: .componentMismatch)
        }
        return AuthenticatedPeer(component: actualComponent, pid: credential.pid)
    }
}
