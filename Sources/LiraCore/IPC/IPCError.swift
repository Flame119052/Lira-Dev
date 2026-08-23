import Foundation

/// Failures on the authenticated IPC plane. Auth rejections are also
/// recorded on the ledger as `ipc.auth_failed` (see `IPCEventType`).
public enum IPCError: Error, Equatable, Sendable {
    public enum RejectionReason: String, Sendable, Equatable {
        case componentMismatch
        case pidNotAllowed
        case parentPIDMismatch
        case codesignInvalid
        case noVerificationConfigured
        case credentialUnreadable
    }

    case peerRejected(reason: RejectionReason)
    case unsupportedVersion(UInt8)
    case frameTooLarge(bytes: Int)
    case disconnected
    case handshakeFailed
    case invalidFrame
    case socketPathTooLong(path: String)
    case listenFailed(errno: Int32)
    case connectFailed(errno: Int32)
}
