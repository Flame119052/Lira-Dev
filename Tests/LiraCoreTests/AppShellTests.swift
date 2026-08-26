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
    func testConnectToEmptyLedgerShowsEmptyNotError() throws {
        let host = try AppShellHarness.make(recordLaunch: false)
        defer { host.stop() }

        let store = EventLogStore(client: host.makeAppClient())
        try store.connect()
        defer { store.stop() }
        XCTAssertEqual(store.state, .empty)
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
