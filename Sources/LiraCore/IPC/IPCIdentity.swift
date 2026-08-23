import CryptoKit
import Darwin
import Foundation

/// Stable name of a Lira component that owns one IPC channel
/// (`lira.core`, `lira.tcc-helper`, …).
public struct ComponentID: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Who a channel will talk to. At least one verification rule should be
/// set for production authenticators:
/// - `codeSigningRequirement` — SecRequirement string for signed helpers
/// - `allowedPeerPIDs` — explicit peer pid allowlist (parent recorded the
///   child pid at spawn; this is how #75 sandboxed children authenticate
///   when they share the app's ad-hoc signature)
/// - `allowedParentPID` — extra constraint: peer must be this pid or a
///   direct child of it. Not enough by itself for sibling containment —
///   two children of the same parent would both pass. Pair it with
///   `allowedPeerPIDs` set to that child's pid.
///
/// A child channel with `codeSigningRequirement == nil` is valid: containment
/// then comes from the pid allowlist, not from team-ID matching.
public struct PeerIdentity: Sendable, Equatable {
    public let component: ComponentID
    public let codeSigningRequirement: String?
    public let allowedPeerPIDs: Set<pid_t>?
    public let allowedParentPID: pid_t?

    public init(
        component: ComponentID,
        codeSigningRequirement: String? = nil,
        allowedPeerPIDs: Set<pid_t>? = nil,
        allowedParentPID: pid_t? = nil
    ) {
        self.component = component
        self.codeSigningRequirement = codeSigningRequirement
        self.allowedPeerPIDs = allowedPeerPIDs
        self.allowedParentPID = allowedParentPID
    }

    public var hasVerificationRule: Bool {
        // Parent-pid alone is not containment (siblings share a parent).
        codeSigningRequirement != nil || allowedPeerPIDs != nil
    }
}

/// Wire-level peer credential. Unix sockets produce a pid (and usually an
/// audit token via `LOCAL_PEERTOKEN`); XPC helpers (#47) produce an audit
/// token. Both resolve to a pid for pid-allowlist / parent-pid checks.
public enum PeerCredential: Sendable, Equatable {
    case processID(pid_t)
    case auditToken(PeerAuditToken)

    public var pid: pid_t {
        switch self {
        case .processID(let pid):
            return pid
        case .auditToken(let token):
            return token.pid
        }
    }
}

/// `audit_token_t` wrapper so the value can cross Swift concurrency and
/// stay `Equatable` for tests. #47 will construct this from
/// `xpc_connection_get_audit_token`.
public struct PeerAuditToken: Sendable, Equatable {
    public let words: [UInt32]

    public init(_ token: audit_token_t) {
        self.words = [
            token.val.0, token.val.1, token.val.2, token.val.3,
            token.val.4, token.val.5, token.val.6, token.val.7,
        ]
    }

    public var raw: audit_token_t {
        var token = audit_token_t()
        token.val = (
            words[0], words[1], words[2], words[3],
            words[4], words[5], words[6], words[7]
        )
        return token
    }

    public var pid: pid_t {
        audit_token_to_pid(raw)
    }
}

public struct AuthenticatedPeer: Sendable, Equatable {
    public let component: ComponentID
    public let pid: pid_t
}

/// One named, isolated channel: its own socket path and its own expected
/// peer. Credentials accepted on channel A are not valid on channel B.
public struct IPCChannel: Sendable, Equatable {
    public let name: String
    public let address: IPCAddress
    public let expectedPeer: PeerIdentity
    /// Who the *server* must be, checked by `IPCClient` from
    /// `LOCAL_PEERPID` / audit token after connect. Distinguishes another
    /// process binding a vacant path; same-uid same-binary impersonation
    /// of a down server cannot be proven on Unix sockets (see
    /// `docs/event-ledger.md`). Nil skips the check.
    public let expectedServer: PeerIdentity?

    public init(
        name: String,
        address: IPCAddress,
        expectedPeer: PeerIdentity,
        expectedServer: PeerIdentity? = nil
    ) {
        self.name = name
        self.address = address
        self.expectedPeer = expectedPeer
        self.expectedServer = expectedServer
    }

    public var socketURL: URL {
        switch address {
        case .unixSocket(let path):
            return path
        }
    }

    /// Stable effect-aggregate for this channel so auth failures group
    /// together when read back from the ledger.
    public var aggregateID: UUID {
        Self.aggregateID(for: name)
    }

    public static func aggregateID(for name: String) -> UUID {
        let digest = SHA256.hash(data: Data("lira.ipc.channel:\(name)".utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            (bytes[6] & 0x0F) | 0x50,
            bytes[7],
            (bytes[8] & 0x3F) | 0x80,
            bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum ProcessIdentity {
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard written == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
