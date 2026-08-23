import Foundation

/// Where an IPC channel listens. The only legal address is an owned
/// Unix-domain socket path — there is no TCP/localhost case, so an
/// unauthenticated loopback port cannot be constructed (ADR-0006).
public enum IPCAddress: Sendable, Equatable {
    case unixSocket(path: URL)
}
