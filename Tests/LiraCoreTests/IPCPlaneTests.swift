import Darwin
import Foundation
import XCTest
@testable import LiraCore

/// The IPC plane: owned Unix-domain sockets, peer authentication, versioned
/// frames, invalidate/reconnect, and ledger-recorded auth failures.
/// Unauthenticated localhost TCP is structurally absent — not a runtime path.
final class IPCAddressTests: XCTestCase {
    func testAddressIsUnixSocketOnly() {
        let path = URL(fileURLWithPath: "/tmp/lira-ipc-test")
        let address = IPCAddress.unixSocket(path: path)
        switch address {
        case .unixSocket(let resolved):
            XCTAssertEqual(resolved.path, path.path)
        }
    }

    func testIPCSourcesDoNotBindTCPLocalhost() throws {
        // Tests/LiraCoreTests/IPCPlaneTests.swift → repo root → Sources/LiraCore
        let ipcRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LiraCore")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ipcRoot.path),
            "expected LiraCore sources at \(ipcRoot.path)"
        )

        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: ipcRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("AF_INET")
                    || trimmed.contains("INADDR_LOOPBACK")
                    || trimmed.contains("127.0.0.1")
                    || trimmed.contains("0.0.0.0")
                {
                    hits.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(
            hits, [],
            "LiraCore must not bind or mention TCP localhost: \(hits)"
        )
    }
}

final class IPCFramingTests: XCTestCase {
    func testRoundTripPreservesKindAndPayload() throws {
        let payload = Data("hello-lira".utf8)
        let frame = try IPCFrame.encode(
            version: IPCProtocol.currentVersion,
            kind: .request,
            payload: payload
        )
        let decoded = try IPCFrame.decode(frame)
        XCTAssertEqual(decoded.version, IPCProtocol.currentVersion)
        XCTAssertEqual(decoded.kind, .request)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testUnsupportedVersionIsRejectedBeforePayloadIsTakenAsARequest() throws {
        let frame = try IPCFrame.encode(version: 99, kind: .request, payload: Data("x".utf8))
        XCTAssertThrowsError(try IPCFrame.decode(frame)) { error in
            XCTAssertEqual(error as? IPCError, .unsupportedVersion(99))
        }
    }

    func testFrameLargerThanCapIsRejected() {
        let oversized = Data(repeating: 0x61, count: IPCProtocol.maxFramePayloadBytes + 1)
        XCTAssertThrowsError(
            try IPCFrame.encode(
                version: IPCProtocol.currentVersion,
                kind: .request,
                payload: oversized
            )
        ) { error in
            guard case .frameTooLarge = error as? IPCError else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
    }
}

final class IPCRoundTripTests: XCTestCase {
    func testClientSendReturnsServerResponseThroughOwnedUnixSocket() throws {
        let harness = try IPCTestHarness.echo(channelName: "round-trip")
        defer { harness.stop() }

        let reply = try harness.client.send(Data("ping".utf8))
        XCTAssertEqual(reply, Data("ping".utf8))
    }

    func testSocketDirectoryIsOwnerOnly() throws {
        let harness = try IPCTestHarness.echo(channelName: "perms")
        defer { harness.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: harness.directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.uint16Value, 0o700)
    }

    func testUnsupportedVersionOnTheWireIsRejected() throws {
        let harness = try IPCTestHarness.echo(channelName: "bad-version")
        defer { harness.stop() }

        try harness.client.sendRawFrame(
            version: 99,
            kind: .request,
            payload: Data("should-not-run".utf8)
        )
        XCTAssertThrowsError(try harness.client.send(Data("after".utf8))) { error in
            XCTAssertEqual(error as? IPCError, .disconnected)
        }
    }
}

final class IPCAuthTests: XCTestCase {
    func testPeerPIDMismatchIsRejectedAndRecordedOnTheLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let path = directory.appendingPathComponent("s")
        defer { try? FileManager.default.removeItem(at: directory) }

        let channel = IPCChannel(
            name: "pid-mismatch",
            address: .unixSocket(path: path),
            expectedPeer: PeerIdentity(
                component: ComponentID("lira.helper-b"),
                allowedPeerPIDs: [1]
            )
        )
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        try server.start()
        defer { server.stop() }

        let client = IPCClient(channel: channel, component: ComponentID("lira.helper-b"))
        XCTAssertThrowsError(try client.connect())

        let events = try ledger.events(forAggregateID: channel.aggregateID)
        XCTAssertEqual(events.map(\.eventType), [IPCEventType.authFailed])
        XCTAssertEqual(events[0].aggregateKind, .effect)
        XCTAssertEqual(events[0].provenance.producer, "lira.ipc")
        let payload = try events[0].decodedPayload(as: IPCAuthFailedPayload.self)
        XCTAssertEqual(payload.channel, "pid-mismatch")
        XCTAssertEqual(payload.reason, IPCError.RejectionReason.pidNotAllowed.rawValue)
        XCTAssertEqual(payload.expectedComponent, "lira.helper-b")
        XCTAssertEqual(payload.peerPID, Int32(getpid()))
    }

    func testCompromiseOfOneChannelDoesNotOpenAnother() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let helperA = ComponentID("lira.helper-a")
        let helperB = ComponentID("lira.helper-b")
        let pid = getpid()

        let channelA = IPCChannel(
            name: "contain-a",
            address: .unixSocket(path: directory.appendingPathComponent("a")),
            expectedPeer: PeerIdentity(component: helperA, allowedPeerPIDs: [pid])
        )
        let channelB = IPCChannel(
            name: "contain-b",
            address: .unixSocket(path: directory.appendingPathComponent("b")),
            expectedPeer: PeerIdentity(component: helperB, allowedPeerPIDs: [1])
        )

        let serverA = IPCServer(
            channel: channelA,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        let serverB = IPCServer(
            channel: channelB,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        try serverA.start()
        try serverB.start()
        defer {
            serverA.stop()
            serverB.stop()
        }

        let clientA = IPCClient(channel: channelA, component: helperA)
        try clientA.connect()
        XCTAssertEqual(try clientA.send(Data("ok-a".utf8)), Data("ok-a".utf8))

        let clientB = IPCClient(channel: channelB, component: helperA)
        XCTAssertThrowsError(try clientB.connect())

        XCTAssertEqual(try clientA.send(Data("still-a".utf8)), Data("still-a".utf8))

        let failures = try ledger.events(forAggregateID: channelB.aggregateID)
        XCTAssertEqual(failures.map(\.eventType), [IPCEventType.authFailed])
        XCTAssertEqual(try ledger.events(forAggregateID: channelA.aggregateID), [])
    }

    func testComponentMismatchDoesNotGrantTheOtherChannel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let helperA = ComponentID("lira.helper-a")
        let helperB = ComponentID("lira.helper-b")
        let pid = getpid()

        let channelB = IPCChannel(
            name: "component-b",
            address: .unixSocket(path: directory.appendingPathComponent("b")),
            expectedPeer: PeerIdentity(component: helperB, allowedPeerPIDs: [pid])
        )
        let serverB = IPCServer(
            channel: channelB,
            authenticator: AllowlistPeerAuthenticator(actualComponent: helperA),
            ledger: ledger,
            onRequest: { $0 }
        )
        try serverB.start()
        defer { serverB.stop() }

        let client = IPCClient(channel: channelB, component: helperA)
        XCTAssertThrowsError(try client.connect())

        let payload = try ledger.events(forAggregateID: channelB.aggregateID)[0]
            .decodedPayload(as: IPCAuthFailedPayload.self)
        XCTAssertEqual(payload.reason, IPCError.RejectionReason.componentMismatch.rawValue)
        XCTAssertEqual(payload.observedComponent, helperA.rawValue)
        XCTAssertEqual(payload.expectedComponent, helperB.rawValue)
    }

    func testCodesignRequirementRejectsANonMatchingPeer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let channel = IPCChannel(
            name: "codesign",
            address: .unixSocket(path: directory.appendingPathComponent("s")),
            expectedPeer: PeerIdentity(
                component: ComponentID("lira.tcc-helper"),
                codeSigningRequirement: "identifier \"com.lira.nonexistent-helper\""
            )
        )
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        try server.start()
        defer { server.stop() }

        let client = IPCClient(channel: channel, component: ComponentID("lira.tcc-helper"))
        XCTAssertThrowsError(try client.connect())

        let payload = try ledger.events(forAggregateID: channel.aggregateID)[0]
            .decodedPayload(as: IPCAuthFailedPayload.self)
        XCTAssertEqual(payload.reason, IPCError.RejectionReason.codesignInvalid.rawValue)
    }

    func testNilCodesignRequirementStillContainsViaParentPID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let child = ComponentID("lira.child")
        let channelOK = IPCChannel(
            name: "child-ok",
            address: .unixSocket(path: directory.appendingPathComponent("ok")),
            expectedPeer: PeerIdentity(
                component: child,
                codeSigningRequirement: nil,
                allowedPeerPIDs: [getpid()],
                allowedParentPID: getpid()
            )
        )
        let channelDenied = IPCChannel(
            name: "child-denied",
            address: .unixSocket(path: directory.appendingPathComponent("no")),
            expectedPeer: PeerIdentity(
                component: child,
                codeSigningRequirement: nil,
                allowedParentPID: 0
            )
        )
        let serverOK = IPCServer(
            channel: channelOK,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        let serverDenied = IPCServer(
            channel: channelDenied,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        try serverOK.start()
        try serverDenied.start()
        defer {
            serverOK.stop()
            serverDenied.stop()
        }

        let okClient = IPCClient(channel: channelOK, component: child)
        try okClient.connect()
        XCTAssertEqual(try okClient.send(Data("child".utf8)), Data("child".utf8))

        let deniedClient = IPCClient(channel: channelDenied, component: child)
        XCTAssertThrowsError(try deniedClient.connect())
        XCTAssertEqual(
            try ledger.events(forAggregateID: channelDenied.aggregateID).map(\.eventType),
            [IPCEventType.authFailed]
        )
    }
}

final class IPCReconnectTests: XCTestCase {
    func testInvalidateThenReconnectAllowsASubsequentRequest() throws {
        let harness = try IPCTestHarness.echo(channelName: "reconnect")
        defer { harness.stop() }

        XCTAssertEqual(try harness.client.send(Data("before".utf8)), Data("before".utf8))
        harness.server.invalidateConnectedPeers()
        XCTAssertThrowsError(try harness.client.send(Data("during".utf8))) { error in
            XCTAssertEqual(error as? IPCError, .invalidated)
        }
        try harness.client.reconnect()
        XCTAssertEqual(try harness.client.send(Data("after".utf8)), Data("after".utf8))
    }

    func testAuthenticatedConnectionSurvivesBeyondHandshakeTimeout() throws {
        let harness = try IPCTestHarness.echo(channelName: "idle")
        defer { harness.stop() }
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(try harness.client.send(Data("still".utf8)), Data("still".utf8))
    }
}

final class IPCRemediationTests: XCTestCase {
    func testClaimedComponentMustMatchExpectedEvenWhenPIDIsAllowed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let helperB = ComponentID("lira.helper-b")
        let helperA = ComponentID("lira.helper-a")
        let channel = IPCChannel(
            name: "claim-mismatch",
            address: .unixSocket(path: directory.appendingPathComponent("s")),
            expectedPeer: PeerIdentity(component: helperB, allowedPeerPIDs: [getpid()])
        )
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        try server.start()
        defer { server.stop() }

        let client = IPCClient(channel: channel, component: helperA)
        XCTAssertThrowsError(try client.connect())
        let payload = try ledger.events(forAggregateID: channel.aggregateID)[0]
            .decodedPayload(as: IPCAuthFailedPayload.self)
        XCTAssertEqual(payload.reason, IPCError.RejectionReason.componentMismatch.rawValue)
        XCTAssertEqual(payload.observedComponent, helperA.rawValue)
    }

    func testOversizedHandshakeComponentStillRecordsABoundedAuthFailure() throws {
        let harnessDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let path = harnessDirectory.appendingPathComponent("s")
        defer { try? FileManager.default.removeItem(at: harnessDirectory) }

        let channel = IPCChannel(
            name: "oversize",
            address: .unixSocket(path: path),
            expectedPeer: PeerIdentity(
                component: ComponentID("lira.helper-b"),
                allowedPeerPIDs: [1]
            )
        )
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        try server.start()
        defer { server.stop() }

        // Larger than the component cap, still under the frame cap so the
        // handshake is delivered (the original attack used ~1 MiB names).
        let huge = String(repeating: "a", count: 8_192)
        let handshake = try JSONEncoder().encode(["component": huge])
        XCTAssertLessThanOrEqual(handshake.count, IPCProtocol.maxFramePayloadBytes)

        let fd = try UnixSocket.make()
        defer { UnixSocket.close(fd) }
        try UnixSocket.connect(fd: fd, path: path)
        try IPCFrame.write(to: fd, kind: .handshake, payload: handshake)
        _ = try? IPCFrame.read(from: fd)

        let events = try ledger.events(forAggregateID: channel.aggregateID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, IPCEventType.authFailed)
        XCTAssertLessThan(events[0].payload.count, 4096)
        let payload = try events[0].decodedPayload(as: IPCAuthFailedPayload.self)
        XCTAssertEqual(payload.reason, IPCError.RejectionReason.handshakeRejected.rawValue)
        XCTAssertEqual(
            payload.observedComponent?.utf8.count,
            IPCProtocol.maxComponentNameUTF8Count
        )
    }

    func testSecondServerOnTheSamePathFailsWithoutStealingTheSocket() throws {
        let harness = try IPCTestHarness.echo(channelName: "owned")
        defer { harness.stop() }

        let usurper = IPCServer(
            channel: harness.channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL()),
            onRequest: { _ in Data("stolen".utf8) }
        )
        XCTAssertThrowsError(try usurper.start()) { error in
            guard case .alreadyInUse = error as? IPCError else {
                return XCTFail("expected alreadyInUse, got \(error)")
            }
        }
        XCTAssertEqual(try harness.client.send(Data("still-owner".utf8)), Data("still-owner".utf8))
    }

    func testClientRejectsAServerWhosePIDIsNotAllowlisted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let channel = IPCChannel(
            name: "server-pid",
            address: .unixSocket(path: directory.appendingPathComponent("s")),
            expectedPeer: PeerIdentity(
                component: ComponentID("lira.test"),
                allowedPeerPIDs: [getpid()]
            ),
            expectedServer: PeerIdentity(
                component: ComponentID("lira.core"),
                allowedPeerPIDs: [1]
            )
        )
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL()),
            onRequest: { $0 }
        )
        try server.start()
        defer { server.stop() }

        let client = IPCClient(channel: channel, component: ComponentID("lira.test"))
        XCTAssertThrowsError(try client.connect()) { error in
            XCTAssertEqual(error as? IPCError, .peerRejected(reason: .pidNotAllowed))
        }
    }

    func testConcurrentSendsKeepRequestAndResponsePaired() throws {
        let harness = try IPCTestHarness.echo(channelName: "concurrent")
        defer { harness.stop() }

        final class State: @unchecked Sendable {
            let lock = NSLock()
            var replies: [Int: Data] = [:]
            var failures: [Error] = []
        }
        let state = State()
        let group = DispatchGroup()
        for index in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let payload = Data("req-\(index)".utf8)
                do {
                    let reply = try harness.client.send(payload)
                    state.lock.lock()
                    state.replies[index] = reply
                    state.lock.unlock()
                } catch {
                    state.lock.lock()
                    state.failures.append(error)
                    state.lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(state.failures.map { "\($0)" }, [])
        for index in 0..<32 {
            XCTAssertEqual(state.replies[index], Data("req-\(index)".utf8))
        }
    }

    func testSeventeenthConnectionIsClosedWithoutALedgerRow() throws {
        let harness = try IPCTestHarness.echo(channelName: "cap")
        defer { harness.stop() }

        var idle: [Int32] = []
        defer { idle.forEach(UnixSocket.close) }
        for _ in 0..<(IPCProtocol.maxConcurrentConnections - 1) {
            let fd = try UnixSocket.make()
            try UnixSocket.connect(fd: fd, path: harness.channel.socketURL)
            idle.append(fd)
        }
        Thread.sleep(forTimeInterval: 0.2)

        let extra = try UnixSocket.make()
        defer { UnixSocket.close(extra) }
        try UnixSocket.connect(fd: extra, path: harness.channel.socketURL)
        XCTAssertThrowsError(try IPCFrame.read(from: extra))
        XCTAssertEqual(
            try harness.ledger.events(forAggregateID: harness.channel.aggregateID),
            []
        )
        XCTAssertEqual(try harness.client.send(Data("still".utf8)), Data("still".utf8))
    }

    func testCloseCanInterruptAHungInFlightSend() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hang = DispatchSemaphore(value: 0)
        defer { hang.signal() }
        let channel = IPCChannel(
            name: "hung-send",
            address: .unixSocket(path: directory.appendingPathComponent("s")),
            expectedPeer: PeerIdentity(
                component: ComponentID("lira.test"),
                allowedPeerPIDs: [getpid()]
            )
        )
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL()),
            onRequest: { _ in
                hang.wait()
                return Data("late".utf8)
            }
        )
        try server.start()
        defer { server.stop() }
        let client = IPCClient(channel: channel, component: ComponentID("lira.test"))
        try client.connect()

        let sendStarted = XCTestExpectation(description: "send entered")
        let sendFinished = XCTestExpectation(description: "send returned")
        let state = NSLock()
        var sendError: Error?
        DispatchQueue.global().async {
            sendStarted.fulfill()
            do {
                _ = try client.send(Data("hang".utf8))
            } catch {
                state.lock()
                sendError = error
                state.unlock()
            }
            sendFinished.fulfill()
        }
        wait(for: [sendStarted], timeout: 1)
        Thread.sleep(forTimeInterval: 0.2)
        let closeStarted = Date()
        client.close()
        XCTAssertLessThan(Date().timeIntervalSince(closeStarted), 1.0)
        wait(for: [sendFinished], timeout: 2)
        state.lock()
        let error = sendError
        state.unlock()
        XCTAssertNotNil(error)
    }

    func testOversizedSendReturnsWithoutHangingTheClient() throws {
        let harness = try IPCTestHarness.echo(channelName: "too-big")
        defer { harness.stop() }
        let tooBig = Data(count: IPCProtocol.maxFramePayloadBytes + 1)
        let started = Date()
        XCTAssertThrowsError(try harness.client.send(tooBig)) { error in
            guard case .frameTooLarge = error as? IPCError else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(try harness.client.send(Data("after".utf8)), Data("after".utf8))
    }

    func testPreparePathDoesNotDeleteANonSocketCollision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let collision = directory.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let sentinel = collision.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try UnixSocket.preparePath(collision)) { error in
            guard case .alreadyInUse = error as? IPCError else {
                return XCTFail("expected alreadyInUse, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testSequentialAuthFailuresAreBoundedAgainstLedgerAmplification() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lira-i-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = IPCChannel(
            name: "drip",
            address: .unixSocket(path: directory.appendingPathComponent("s")),
            expectedPeer: PeerIdentity(
                component: ComponentID("lira.expected"),
                allowedPeerPIDs: [getpid()]
            )
        )
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let server = IPCServer(
            channel: channel,
            authenticator: DarwinPeerAuthenticator(),
            ledger: ledger,
            onRequest: { $0 }
        )
        try server.start()
        defer { server.stop() }

        for _ in 0..<64 {
            let client = IPCClient(channel: channel, component: ComponentID("lira.wrong"))
            XCTAssertThrowsError(try client.connect())
            client.close()
        }
        let events = try ledger.events(forAggregateID: channel.aggregateID)
        XCTAssertLessThanOrEqual(events.count, IPCProtocol.maxAuthFailureRowsPerWindow)
        XCTAssertEqual(Set(events.map(\.eventType)), [IPCEventType.authFailed])
    }
}
