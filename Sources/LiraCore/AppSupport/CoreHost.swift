import Darwin
import Foundation

public enum CoreHostError: Error, Equatable, Sendable {
    /// Ledger file could not be opened (corrupt, inaccessible, or written
    /// by a newer schema). The app must stay alive and show this as the
    /// ledger-unavailable error — not crash, and not pretend the log is empty.
    case ledgerUnavailable
}

/// Owns the ledger and the ticket-2 IPC server. The SwiftUI layer never
/// opens the database; it talks through `makeAppClient()`.
public final class CoreHost: @unchecked Sendable {
    let ledger: EventLedger
    public let ledgerURL: URL
    private let server: IPCServer
    private let channel: IPCChannel

    private init(ledger: EventLedger, ledgerURL: URL, server: IPCServer, channel: IPCChannel) {
        self.ledger = ledger
        self.ledgerURL = ledgerURL
        self.server = server
        self.channel = channel
    }

    public static func start(
        ledgerURL: URL,
        socketURL: URL,
        recordLaunch: Bool
    ) throws -> CoreHost {
        let opened: EventLedger
        do {
            try FileManager.default.createDirectory(
                at: ledgerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            opened = try EventLedger(databaseURL: ledgerURL)
        } catch {
            throw CoreHostError.ledgerUnavailable
        }

        let pid = getpid()
        let peer = PeerIdentity(component: LiraComponent.app, allowedPeerPIDs: [pid])
        let serverIdentity = PeerIdentity(component: LiraComponent.core, allowedPeerPIDs: [pid])
        let channel = IPCChannel(
            name: "lira.core",
            address: .unixSocket(path: socketURL),
            expectedPeer: peer,
            expectedServer: serverIdentity
        )
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: opened,
            onRequest: { LedgerIPC.handle($0, ledger: opened) }
        )
        try server.start()

        if recordLaunch {
            try recordLaunchEvent(on: opened)
        }

        return CoreHost(ledger: opened, ledgerURL: ledgerURL, server: server, channel: channel)
    }

    public func makeAppClient() -> IPCClient {
        IPCClient(channel: channel, component: LiraComponent.app)
    }

    public func invalidateConnectedPeers() {
        server.invalidateConnectedPeers()
    }

    public func stop() {
        server.stop()
    }

    private static func recordLaunchEvent(on ledger: EventLedger) throws {
        try ledger.append(
            PendingEvent(
                aggregateKind: .effect,
                aggregateID: Self.launchAggregateID,
                eventType: AppEventType.launched,
                payloadSchemaVersion: 1,
                provenance: EventProvenance(producer: AppProducer.shell),
                payload: Data("{}".utf8)
            )
        )
    }

    /// Stable effect aggregate so successive launches group in the log.
    static let launchAggregateID: UUID = {
        IPCChannel.aggregateID(for: "lira.app")
    }()
}
