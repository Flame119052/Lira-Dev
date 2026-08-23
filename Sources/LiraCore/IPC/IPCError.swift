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
        case handshakeRejected
        /// First-frame receive timed out before authentication finished.
        case handshakeTimedOut
    }

    case peerRejected(reason: RejectionReason)
    case unsupportedVersion(UInt8)
    case frameTooLarge(bytes: Int)
    case disconnected
    /// Server sent `invalidate`. Distinct from a drop so #36 can choose
    /// whether to reconnect.
    case invalidated
    /// Receive timeout fired (handshake only; authenticated sockets wait).
    case timedOut
    case handshakeFailed
    case invalidFrame
    case socketPathTooLong(path: String)
    case alreadyInUse(path: String)
    case listenFailed(errno: Int32)
    case connectFailed(errno: Int32)
}
