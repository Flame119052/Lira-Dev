import Darwin
import Foundation

/// Listens on an owned Unix-domain socket, authenticates each peer, and
/// answers `IPCClient.send` with the request handler's `Data`.
public final class IPCServer: @unchecked Sendable {
    private let channel: IPCChannel
    private let authenticator: any PeerAuthenticator
    private let ledger: EventLedger
    private let onRequest: @Sendable (Data) throws -> Data
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFDs: [Int32] = []
    private var stopped = true
    private var acceptThread: Thread?

    public init(
        channel: IPCChannel,
        authenticator: any PeerAuthenticator,
        ledger: EventLedger,
        onRequest: @escaping @Sendable (Data) throws -> Data
    ) {
        self.channel = channel
        self.authenticator = authenticator
        self.ledger = ledger
        self.onRequest = onRequest
    }

    public func start() throws {
        try UnixSocket.preparePath(channel.socketURL)
        let fd = try UnixSocket.make()
        do {
            try UnixSocket.bind(fd: fd, path: channel.socketURL)
            try UnixSocket.listen(fd: fd)
        } catch {
            UnixSocket.close(fd)
            throw error
        }
        lock.lock()
        listenFD = fd
        stopped = false
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "lira.ipc.\(channel.name)"
        lock.lock()
        acceptThread = thread
        lock.unlock()
        thread.start()
    }

    public func invalidateConnectedPeers() {
        let fds = snapshotClients()
        for fd in fds {
            try? IPCFrame.write(to: fd, kind: .invalidate, payload: Data())
            removeClient(fd)
            UnixSocket.close(fd)
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let listen = listenFD
        listenFD = -1
        let clients = clientFDs
        clientFDs = []
        lock.unlock()
        UnixSocket.close(listen)
        for fd in clients {
            UnixSocket.close(fd)
        }
        try? FileManager.default.removeItem(at: channel.socketURL)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let listen = listenFD
            let isStopped = stopped
            lock.unlock()
            if isStopped || listen < 0 { return }
            do {
                let client = try UnixSocket.accept(fd: listen)
                addClient(client)
                Thread.detachNewThread { [weak self] in
                    self?.handle(client: client)
                }
            } catch {
                lock.lock()
                let isStopped = stopped
                lock.unlock()
                if isStopped { return }
            }
        }
    }

    private func handle(client fd: Int32) {
        defer {
            removeClient(fd)
            UnixSocket.close(fd)
        }
        var observed: ComponentID?
        var peerPID: pid_t?
        do {
            let credential = try UnixSocket.peerCredential(fd: fd)
            peerPID = credential.pid
            let first = try IPCFrame.read(from: fd)
            guard first.kind == .handshake else {
                throw IPCError.handshakeFailed
            }
            let claimed = try? JSONDecoder().decode(
                HandshakePayload.self,
                from: first.payload
            )
            observed = claimed.map { ComponentID($0.component) }
            _ = try authenticator.authenticate(
                credential: credential,
                expected: channel.expectedPeer
            )
            try IPCFrame.write(to: fd, kind: .handshakeAck, payload: Data())
            while true {
                lock.lock()
                let isStopped = stopped
                lock.unlock()
                if isStopped { return }
                let frame = try IPCFrame.read(from: fd)
                switch frame.kind {
                case .request:
                    let response = try onRequest(frame.payload)
                    try IPCFrame.write(to: fd, kind: .response, payload: response)
                case .invalidate:
                    return
                default:
                    return
                }
            }
        } catch let error as IPCError {
            if case .peerRejected(let reason) = error {
                try? IPCAuthFailureRecorder.record(
                    on: ledger,
                    channel: channel,
                    reason: reason,
                    observedComponent: observed,
                    peerPID: peerPID
                )
            }
            return
        } catch {
            return
        }
    }

    private func addClient(_ fd: Int32) {
        lock.lock()
        clientFDs.append(fd)
        lock.unlock()
    }

    private func removeClient(_ fd: Int32) {
        lock.lock()
        clientFDs.removeAll { $0 == fd }
        lock.unlock()
    }

    private func snapshotClients() -> [Int32] {
        lock.lock()
        let fds = clientFDs
        lock.unlock()
        return fds
    }
}

struct HandshakePayload: Codable, Equatable {
    let component: String
}
