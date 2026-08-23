import Darwin
import Foundation
@testable import LiraCore

/// Boots a real Unix-socket server + client against a temporary owned path.
enum IPCTestHarness {
    struct Pair {
        let server: IPCServer
        let client: IPCClient
        let ledger: EventLedger
        let channel: IPCChannel
        let directory: URL

        func stop() {
            client.close()
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func echo(
        channelName: String,
        expected: PeerIdentity? = nil,
        authenticator: (any PeerAuthenticator)? = nil,
        clientComponent: ComponentID? = nil
    ) throws -> Pair {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let path = directory.appendingPathComponent("s")
        let pid = getpid()
        let identity = expected ?? PeerIdentity(
            component: ComponentID("lira.test"),
            allowedPeerPIDs: [pid]
        )
        let channel = IPCChannel(
            name: channelName,
            address: .unixSocket(path: path),
            expectedPeer: identity,
            expectedServer: PeerIdentity(
                component: ComponentID("lira.core"),
                allowedPeerPIDs: [pid]
            )
        )
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let server = IPCServer(
            channel: channel,
            authenticator: authenticator ?? DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        try server.start()
        let client = IPCClient(
            channel: channel,
            component: clientComponent ?? identity.component
        )
        try client.connect()
        return Pair(server: server, client: client, ledger: ledger, channel: channel, directory: directory)
    }
}
