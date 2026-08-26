import Darwin
import Foundation
import XCTest
@testable import LiraCore

/// App shell (#36): CoreHost + listEvents IPC + EventLogStore.
/// The SwiftUI window is a thin view over this store; behavior is proven here.
final class LedgerIPCTests: XCTestCase {
    func testEmptyLedgerReturnsOkAndNoEvents() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let page = try host.listEvents(afterSequence: 0)
        XCTAssertTrue(page.ok)
        XCTAssertEqual(page.events, [])
        XCTAssertEqual(page.error, nil)
        XCTAssertEqual(try host.ledger.allEvents(), [])
    }

    func testListEventsReturnsGoalRunStepEffectInSequence() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let goalID = UUID()
        let runID = UUID()
        let stepID = UUID()
        _ = try host.ledger.append(TestSupport.makeEvent(
            index: 1, aggregateKind: .goal, aggregateID: goalID, eventType: LifecycleEventType.goalCreated
        ))
        _ = try host.ledger.append(TestSupport.makeEvent(
            index: 2, aggregateKind: .run, aggregateID: runID, eventType: LifecycleEventType.runCreated
        ))
        _ = try host.ledger.append(TestSupport.makeEvent(
            index: 3, aggregateKind: .step, aggregateID: stepID, eventType: LifecycleEventType.stepCreated
        ))
        _ = try host.ledger.append(TestSupport.makeEvent(
            index: 4, aggregateKind: .effect, eventType: IPCEventType.authFailed
        ))

        let page = try host.listEvents(afterSequence: 0)
        XCTAssertEqual(
            page.events.map(\.eventType),
            [
                LifecycleEventType.goalCreated,
                LifecycleEventType.runCreated,
                LifecycleEventType.stepCreated,
                IPCEventType.authFailed,
            ]
        )
        XCTAssertEqual(page.events.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(try host.ledger.allEvents().map(\.eventType), page.events.map(\.eventType))
    }

    func testAfterSequenceReturnsOnlyNewerEvents() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        _ = try host.ledger.append(TestSupport.makeEvent(index: 1, eventType: "goal.created"))
        let first = try host.listEvents(afterSequence: 0)
        XCTAssertEqual(first.events.map(\.sequence), [1])

        _ = try host.ledger.append(TestSupport.makeEvent(index: 2, eventType: "run.created"))
        let second = try host.listEvents(afterSequence: first.events.last?.sequence ?? 0)
        XCTAssertEqual(second.events.map(\.eventType), ["run.created"])
        XCTAssertEqual(second.events.map(\.sequence), [2])
    }

    func testListEventsPagesWithSQLLimitNotAFullTailPrefix() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        for index in 1...5 {
            _ = try host.ledger.append(TestSupport.makeEvent(index: index, eventType: "goal.created"))
        }
        XCTAssertEqual(try host.ledger.events(afterSequence: 0, limit: 2).map(\.sequence), [1, 2])
        XCTAssertEqual(try host.ledger.events(afterSequence: 2, limit: 2).map(\.sequence), [3, 4])

        let client = host.makeAppClient()
        try client.connect()
        defer { client.close() }
        let page = try LedgerIPC.decodeResponse(
            client.send(LedgerIPC.encodeListEvents(afterSequence: 0, limit: 2))
        )
        XCTAssertEqual(page.events.map(\.sequence), [1, 2])
        XCTAssertFalse(page.reachedEnd)
        let rest = try LedgerIPC.decodeResponse(
            client.send(LedgerIPC.encodeListEvents(afterSequence: 2, limit: 2))
        )
        XCTAssertEqual(rest.events.map(\.sequence), [3, 4])
    }

    func testListEventsTailReturnsTheLatestWindowNotTheStart() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        for index in 1...5 {
            _ = try host.ledger.append(TestSupport.makeEvent(index: index, eventType: "goal.created"))
        }
        let client = host.makeAppClient()
        try client.connect()
        defer { client.close() }
        let page = try LedgerIPC.decodeResponse(
            client.send(LedgerIPC.encodeListEvents(afterSequence: 0, limit: 2, tail: true))
        )
        XCTAssertEqual(page.events.map(\.sequence), [4, 5])
        XCTAssertTrue(page.reachedEnd)
    }

    func testSummariesDoNotInventParentAwaitingOrStartedEvents() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let life = RunLifecycle(ledger: host.ledger)
        let goalID = try life.createGoal(title: "demo")
        let runID = try life.createRun(goalID: goalID)
        let stepID = try life.createStep(runID: runID, kind: "model_turn")
        try life.start(runID)
        try life.start(stepID)

        let listed = try host.listEvents(afterSequence: 0).events.map(\.eventType)
        let recorded = try host.ledger.allEvents().map(\.eventType)
        XCTAssertEqual(listed, recorded)
        XCTAssertFalse(listed.contains("goal.awaiting_approval"))
        XCTAssertFalse(listed.contains("goal.started"))
    }
}

final class CoreHostTests: XCTestCase {
    func testLaunchEffectIsRecordedOnTheLedger() throws {
        let host = try AppShellHarness.make(recordLaunch: true)
        defer { host.stop() }

        let events = try host.ledger.allEvents()
        XCTAssertEqual(events.map(\.eventType), [AppEventType.launched])
        XCTAssertEqual(events[0].aggregateKind, .effect)
        XCTAssertEqual(events[0].provenance.producer, AppProducer.shell)

        let page = try host.listEvents(afterSequence: 0)
        XCTAssertEqual(page.events.map(\.eventType), [AppEventType.launched])
    }

    func testRelaunchOnTheSameDatabaseKeepsHistory() throws {
        let urls = AppShellHarness.makeURLs()
        let first = try CoreHost.start(
            ledgerURL: urls.ledger,
            socketURL: urls.socket,
            recordLaunch: true
        )
        first.stop()

        let second = try CoreHost.start(
            ledgerURL: urls.ledger,
            socketURL: urls.socket,
            recordLaunch: true
        )
        defer { second.stop() }

        let types = try second.ledger.allEvents().map(\.eventType)
        XCTAssertEqual(types, [AppEventType.launched, AppEventType.launched])

        let client = second.makeAppClient()
        try client.connect()
        defer { client.close() }
        let page = try LedgerIPC.decodeResponse(client.send(LedgerIPC.encodeListEvents(afterSequence: 0)))
        XCTAssertEqual(page.events.map(\.eventType), types)
    }

    func testLedgerOpenFailureIsLedgerUnavailableAndLeavesStoreAlive() throws {
        let urls = AppShellHarness.makeURLs()
        try Data("this is not a sqlite database".utf8).write(to: urls.ledger)

        XCTAssertThrowsError(
            try CoreHost.start(ledgerURL: urls.ledger, socketURL: urls.socket, recordLaunch: false)
        ) { error in
            XCTAssertEqual(error as? CoreHostError, .ledgerUnavailable)
        }

        let store = EventLogStore(client: nil)
        store.noteHostFailed(.ledgerUnavailable)
        XCTAssertEqual(store.state, .error(.ledgerUnavailable))
        XCTAssertEqual(store.state, .error(.ledgerUnavailable), "store stays readable after host failure")
    }

    func testApplicationSupportPathComesFromFileManagerNotAHardCodedHome() {
        let expected = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lira", isDirectory: true)
        XCTAssertEqual(LiraPaths.applicationSupportDirectory(), expected)
        XCTAssertLessThan(
            LiraPaths.ipcSocketURL().path.utf8.count,
            LiraPaths.maxUnixSocketPathLength
        )
    }
}

final class EventLogStoreTests: XCTestCase {
    func testProductionConnectOrderShowsEmptyBeforeLaunchEvent() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let store = EventLogStore(client: host.makeAppClient())
        try store.connect()
        defer { store.stop() }
        XCTAssertEqual(store.state, .empty)

        try host.host.recordLaunch()
        try store.poll()
        guard case .loaded(let events) = store.state else {
            return XCTFail("expected loaded log after launch, got \(store.state)")
        }
        XCTAssertEqual(events.map(\.eventType), [AppEventType.launched])
    }

    func testConnectToEmptyLedgerShowsEmptyNotError() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let store = EventLogStore(client: host.makeAppClient())
        try store.connect()
        defer { store.stop() }
        XCTAssertEqual(store.state, .empty)
    }

    func testConnectLoadsOnlyTheLatestWindowNotTheFullLedger() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let total = LedgerIPC.defaultLimit + 20
        for index in 1...total {
            _ = try host.ledger.append(TestSupport.makeEvent(index: index, eventType: "goal.created"))
        }
        let store = EventLogStore(client: host.makeAppClient())
        try store.connect()
        defer { store.stop() }

        guard case .loaded(let events) = store.state else {
            return XCTFail("expected loaded window, got \(store.state)")
        }
        XCTAssertEqual(events.count, LedgerIPC.defaultLimit)
        XCTAssertEqual(events.first?.sequence, Int64(total - LedgerIPC.defaultLimit + 1))
        XCTAssertEqual(events.last?.sequence, Int64(total))
        XCTAssertFalse(events.contains(where: { $0.sequence == 1 }))

        _ = try host.ledger.append(TestSupport.makeEvent(index: total + 1, eventType: "run.created"))
        try store.poll()
        guard case .loaded(let live) = store.state else {
            return XCTFail("expected live window after poll, got \(store.state)")
        }
        XCTAssertEqual(live.count, LedgerIPC.defaultLimit)
        XCTAssertEqual(live.last?.sequence, Int64(total + 1))
        XCTAssertEqual(live.last?.eventType, "run.created")
        XCTAssertFalse(live.contains(where: { $0.sequence == events.first?.sequence }))
    }

    func testFailedInitialTailDoesNotFallBackToAFullLedgerWalk() throws {
        let urls = AppShellHarness.makeURLs()
        let ledger = try EventLedger(databaseURL: urls.ledger)
        let total = LedgerIPC.defaultLimit + 20
        for index in 1...total {
            _ = try ledger.append(TestSupport.makeEvent(index: index, eventType: "goal.created"))
        }

        let pid = getpid()
        let channel = IPCChannel(
            name: "lira.tail-retry",
            address: .unixSocket(path: urls.socket),
            expectedPeer: PeerIdentity(component: LiraComponent.app, allowedPeerPIDs: [pid]),
            expectedServer: PeerIdentity(component: LiraComponent.core, allowedPeerPIDs: [pid])
        )
        let gate = TailRetryGate()
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { data in
                let request = try JSONDecoder().decode(LedgerIPCRequest.self, from: data)
                if gate.shouldFail(request) {
                    return try JSONEncoder().encode(
                        LedgerIPCResponse(ok: false, events: nil, reachedEnd: nil, error: "ledgerUnavailable")
                    )
                }
                return LedgerIPC.handle(data, ledger: ledger)
            }
        )
        try server.start()
        defer { server.stop() }

        let store = EventLogStore(client: IPCClient(channel: channel, component: LiraComponent.app))
        try store.connect()
        defer { store.stop() }
        XCTAssertEqual(store.state, .error(.ledgerUnavailable))

        try store.poll()
        guard case .loaded(let events) = store.state else {
            return XCTFail("retry should load the tail window, got \(store.state)")
        }
        XCTAssertEqual(events.count, LedgerIPC.defaultLimit)
        XCTAssertEqual(events.first?.sequence, Int64(total - LedgerIPC.defaultLimit + 1))
        XCTAssertEqual(events.last?.sequence, Int64(total))

        let seen = gate.snapshot()
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.map(\.tail), [true, true], "recovery must re-request the tail, not page forward from 0")
    }

    func testHandshakeTimeoutStaysOnTheLiveStoreNotDisconnected() throws {
        let urls = AppShellHarness.makeURLs()
        try UnixSocket.preparePath(urls.socket)
        let listenFD = try UnixSocket.make()
        try UnixSocket.bind(fd: listenFD, path: urls.socket)
        try UnixSocket.listen(fd: listenFD)
        defer { UnixSocket.close(listenFD) }

        // Accept and hold so the client can complete connect() and wait for
        // handshakeAck. Without accept, some Darwin builds block on send.
        let holdAccepted = DispatchSemaphore(value: 0)
        defer { holdAccepted.signal() }
        DispatchQueue.global().async {
            guard let accepted = try? UnixSocket.accept(fd: listenFD) else { return }
            holdAccepted.wait()
            UnixSocket.close(accepted)
        }

        let pid = getpid()
        let channel = IPCChannel(
            name: "lira.handshake-timeout",
            address: .unixSocket(path: urls.socket),
            expectedPeer: PeerIdentity(component: LiraComponent.app, allowedPeerPIDs: [pid])
        )
        let live = EventLogStore(client: IPCClient(channel: channel, component: LiraComponent.app))
        defer { live.stop() }
        let placeholder = EventLogStore(client: nil)

        live.connectAndStartPolling()

        XCTAssertEqual(live.state, .error(.timedOut))
        XCTAssertNotEqual(live.state, .error(.disconnected))
        XCTAssertNotEqual(
            placeholder.state,
            live.state,
            "production must keep the live store; remapping a discarded placeholder hides handshake timeout"
        )
    }

    func testPollPicksUpEventsAppendedAfterConnectWithoutReconnect() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let store = EventLogStore(client: host.makeAppClient())
        try store.connect()
        defer { store.stop() }
        XCTAssertEqual(store.state, .empty)

        _ = try host.ledger.append(TestSupport.makeEvent(
            index: 1, aggregateKind: .goal, eventType: LifecycleEventType.goalCreated
        ))
        try store.poll()

        guard case .loaded(let events) = store.state else {
            return XCTFail("expected loaded log, got \(store.state)")
        }
        XCTAssertEqual(events.map(\.eventType), [LifecycleEventType.goalCreated])
        XCTAssertEqual(try host.ledger.allEvents().map(\.eventType), [LifecycleEventType.goalCreated])
    }

    func testPollingTimerPublishesNewRowsWithoutRecreatingTheStore() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let store = EventLogStore(client: host.makeAppClient())
        try store.connect()
        store.startPolling(interval: 0.05)
        defer { store.stop() }
        XCTAssertEqual(store.state, .empty)

        _ = try host.ledger.append(TestSupport.makeEvent(
            index: 1, aggregateKind: .run, eventType: LifecycleEventType.runCreated
        ))

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if case .loaded(let events) = store.state, events.map(\.eventType) == [LifecycleEventType.runCreated] {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("store did not publish the new event via polling, last state \(store.state)")
    }

    func testDisconnectedIsDistinctFromInvalidatedAndFromEmpty() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        let store = EventLogStore(client: host.makeAppClient())
        try store.connect()

        host.invalidateConnectedPeers()
        XCTAssertThrowsError(try store.poll()) { error in
            XCTAssertEqual(error as? IPCError, .invalidated)
        }
        XCTAssertEqual(store.state, .error(.invalidated))

        store.stop()
        host.stop()

        let host2 = try AppShellHarness.make(recordLaunch: false)
        defer { host2.stop() }
        let store2 = EventLogStore(client: host2.makeAppClient())
        try store2.connect()
        host2.stop()
        XCTAssertThrowsError(try store2.poll()) { error in
            XCTAssertEqual(error as? IPCError, .disconnected)
        }
        XCTAssertEqual(store2.state, .error(.disconnected))
        XCTAssertNotEqual(store.state, store2.state)
        XCTAssertNotEqual(store2.state, .empty)
    }

    func testInvalidatedStateIsNotOverwrittenByLaterDisconnect() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        let store = EventLogStore(client: host.makeAppClient())
        try store.connect()
        store.startPolling(interval: 0.05)
        defer {
            store.stop()
            host.stop()
        }

        host.invalidateConnectedPeers()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, store.state != .error(.invalidated) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(store.state, .error(.invalidated))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            store.state,
            .error(.invalidated),
            "later disconnected polls must not replace session revoked"
        )
        try store.poll()
        XCTAssertEqual(store.state, .error(.invalidated))
    }
}

final class AppSourceBoundaryTests: XCTestCase {
    func testAppSourcesDoNotOpenTheLedger() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Lira")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appRoot.path),
            "expected Lira app sources at \(appRoot.path)"
        )

        let forbidden = ["EventLedger", "GRDB", "DatabasePool", "sqlite", "ledger.sqlite"]
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for token in forbidden where trimmed.contains(token) {
                    hits.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(hits, [], "UI sources must not open the ledger: \(hits)")
    }
}

// MARK: - Harness

private final class TailRetryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failedOnce = false
    private var requests: [(after: Int64?, tail: Bool?)] = []

    func shouldFail(_ request: LedgerIPCRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requests.append((request.afterSequence, request.tail))
        if failedOnce { return false }
        failedOnce = true
        return true
    }

    func snapshot() -> [(after: Int64?, tail: Bool?)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private struct AppShellHarness {
    let host: CoreHost
    var ledger: EventLedger { host.ledger }

    func stop() { host.stop() }

    func makeAppClient() -> IPCClient {
        host.makeAppClient()
    }

    func invalidateConnectedPeers() {
        host.invalidateConnectedPeers()
    }

    func listEvents(afterSequence: Int64) throws -> LedgerIPCResponse {
        let client = host.makeAppClient()
        try client.connect()
        defer { client.close() }
        return try LedgerIPC.decodeResponse(
            client.send(LedgerIPC.encodeListEvents(afterSequence: afterSequence))
        )
    }

    static func make(recordLaunch: Bool) throws -> AppShellHarness {
        let urls = makeURLs()
        let host = try CoreHost.start(
            ledgerURL: urls.ledger,
            socketURL: urls.socket,
            recordLaunch: recordLaunch
        )
        return AppShellHarness(host: host)
    }

    static func makeURLs() -> (ledger: URL, socket: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-app-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return (
            ledger: directory.appendingPathComponent("ledger.sqlite"),
            socket: directory.appendingPathComponent("core.sock")
        )
    }
}
