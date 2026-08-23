import Darwin
import Foundation

/// Connects to an owned Unix-domain socket and exchanges request/response
/// payloads. This is the surface #36 (app shell) uses instead of opening
/// the ledger database from the UI process.
///
/// `send` serializes the full write/read exchange, so concurrent callers
/// cannot interleave frames. `close` shuts the socket down first so a
/// hung peer cannot pin the I/O lock forever.
public final class IPCClient: @unchecked Sendable {
    private let channel: IPCChannel
    private let component: ComponentID
    private let lock = NSLock()
    private let ioLock = NSLock()
    private var fd: Int32 = -1

    public init(channel: IPCChannel, component: ComponentID) {
        self.channel = channel
        self.component = component
    }

    public func connect() throws {
        try openSession()
    }

    /// The #36 contract: send opaque bytes, receive the handler's bytes.
    public func send(_ payload: Data) throws -> Data {
        ioLock.lock()
        defer { ioLock.unlock() }
        let socket = try currentFD()
        do {
            try IPCFrame.write(to: socket, kind: .request, payload: payload)
        } catch let error as IPCError where isLocalEncodeError(error) {
            // Encode failed before any bytes hit the socket — keep the
            // session. Draining would block forever on a healthy peer.
            throw error
        } catch {
            throw drainInvalidation(from: socket, fallback: error)
        }
        let frame: IPCFrame.Decoded
        do {
            frame = try IPCFrame.read(from: socket)
        } catch {
            throw drainInvalidation(from: socket, fallback: error)
        }
        switch frame.kind {
        case .response:
            return frame.payload
        case .invalidate:
            markDisconnected(from: socket)
            throw IPCError.invalidated
        default:
            markDisconnected(from: socket)
            throw IPCError.invalidFrame
        }
    }

    public func reconnect() throws {
        close()
        try openSession()
    }

    public func close() {
        lock.lock()
        let socket = fd
        fd = -1
        lock.unlock()
        guard socket >= 0 else { return }
        UnixSocket.shutdown(socket)
        ioLock.lock()
        Darwin.close(socket)
        ioLock.unlock()
    }

    /// Test hook: write a raw (possibly illegal) version so versioning
    /// can be exercised without a second protocol.
    func sendRawFrame(version: UInt8, kind: IPCFrameKind, payload: Data) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        let socket = try currentFD()
        try writeAll(
            fd: socket,
            data: IPCFrame.encode(version: version, kind: kind, payload: payload)
        )
    }

    private func openSession() throws {
        let socket = try UnixSocket.make()
        do {
            try UnixSocket.connect(fd: socket, path: channel.socketURL)
            if let expectedServer = channel.expectedServer {
                let credential = try UnixSocket.peerCredential(fd: socket)
                _ = try DarwinPeerAuthenticator().authenticate(
                    credential: credential,
                    expected: expectedServer,
                    claimed: expectedServer.component
                )
            }
            let handshake = HandshakePayload(component: component.rawValue)
            try IPCFrame.write(
                to: socket,
                kind: .handshake,
                payload: try JSONEncoder().encode(handshake)
            )
            let ack = try IPCFrame.read(from: socket)
            guard ack.kind == .handshakeAck else {
                throw IPCError.handshakeFailed
            }
            UnixSocket.clearReceiveTimeout(fd: socket)
        } catch {
            UnixSocket.close(socket)
            throw error
        }
        lock.lock()
        fd = socket
        lock.unlock()
    }

    private func currentFD() throws -> Int32 {
        lock.lock()
        let socket = fd
        lock.unlock()
        if socket < 0 { throw IPCError.disconnected }
        return socket
    }

    private func markDisconnected(from expected: Int32) {
        lock.lock()
        let socket = fd
        guard socket == expected else {
            lock.unlock()
            return
        }
        fd = -1
        lock.unlock()
        UnixSocket.close(socket)
    }

    private func isLocalEncodeError(_ error: IPCError) -> Bool {
        if case .frameTooLarge = error { return true }
        return false
    }

    /// After the server writes `invalidate` it closes the socket. A later
    /// `send` may fail the write with `.disconnected` while the invalidate
    /// frame is still readable — surface that as `.invalidated` so #36 can
    /// tell revocation from a drop. Bounded so a missing frame cannot hang.
    private func drainInvalidation(from socket: Int32, fallback: Error) -> Error {
        UnixSocket.setReceiveTimeout(fd: socket, seconds: 0.2)
        if (try? IPCFrame.read(from: socket))?.kind == .invalidate {
            markDisconnected(from: socket)
            return IPCError.invalidated
        }
        markDisconnected(from: socket)
        return fallback
    }
}
