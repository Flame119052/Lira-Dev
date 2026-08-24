import XCTest
@testable import LiraCore

/// Kill-and-relaunch of an in-progress run (ticket #35 AC). Mirrors the
/// #33 probe pattern: a helper process writes durable state, the test
/// SIGKILLs it, then a new `RunLifecycle` reconciles from the ledger alone.
final class RunLifecycleKillRelaunchTests: XCTestCase {
    func testKillWhileRunningFailsAsInterrupted() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        try runProbe(url, mode: "running")

        let ledger = try EventLedger(databaseURL: url)
        let report = try ledger.verifyIntegrity()
        XCTAssertTrue(report.isHealthy, "ledger unhealthy after kill: \(report)")

        let lifecycle = RunLifecycle(ledger: ledger)
        let before = try lifecycle.allSnapshots()
        let running = before.filter { $0.state == .running }
        XCTAssertFalse(running.isEmpty, "probe should have left in-flight work")

        let recon = try lifecycle.reconcile()
        XCTAssertFalse(recon.interrupted.isEmpty)

        for snap in try lifecycle.allSnapshots() {
            XCTAssertTrue(
                snap.state.isTerminal,
                "\(snap.kind) \(snap.id) still \(snap.state) after reconcile"
            )
        }
        let failed = try lifecycle.allSnapshots().filter { $0.state == .failed }
        XCTAssertFalse(failed.isEmpty)
        XCTAssertTrue(failed.contains { $0.reason == LifecycleReason.interrupted })

        let sequences = try ledger.allEvents().map(\.sequence)
        XCTAssertEqual(sequences, Array(1...Int64(sequences.count)))

        let eventIDs = try ledger.allEvents().map(\.eventID)
        let second = try lifecycle.reconcile()
        XCTAssertEqual(second.interrupted, [])
        XCTAssertEqual(try ledger.allEvents().map(\.eventID), eventIDs)

        // Command that committed before the kill must not double-apply.
        let replayed = try lifecycle.createGoal(title: "probe-goal", idempotencyKey: "probe-goal")
        XCTAssertEqual(
            try ledger.allEvents().filter { $0.eventType == LifecycleEventType.goalCreated }.count,
            1
        )
        XCTAssertEqual(
            try ledger.events(forAggregateID: replayed).first?.eventType,
            LifecycleEventType.goalCreated
        )

        let final = try ledger.verifyIntegrity()
        XCTAssertTrue(final.isHealthy)
    }

    func testKillWhileAwaitingApprovalResumes() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        try runProbe(url, mode: "awaiting")

        let ledger = try EventLedger(databaseURL: url)
        XCTAssertTrue(try ledger.verifyIntegrity().isHealthy)

        let lifecycle = RunLifecycle(ledger: ledger)
        _ = try lifecycle.reconcile()

        let awaiting = try lifecycle.allSnapshots().filter { $0.state == .awaitingApproval }
        XCTAssertEqual(awaiting.filter { $0.kind == .step }.count, 1)
        let step = try XCTUnwrap(awaiting.first { $0.kind == .step })

        try lifecycle.approve(stepID: step.id)
        XCTAssertEqual(try XCTUnwrap(lifecycle.snapshot(step.id)).state, .running)
    }

    private func runProbe(_ url: URL, mode: String) throws {
        let process = Process()
        process.executableURL = try CrashProbe.executableURL(named: "lifecycle-crash-probe")
        process.arguments = [url.path, mode]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()

        let reader = LineReader(process: process)
        var sawReady = false
        while !sawReady {
            guard try reader.nextLine(deadline: .now + 60) else {
                kill(process.processIdentifier, SIGKILL)
                return XCTFail("probe exited before READY")
            }
            sawReady = reader.lastLine == "READY"
            if Date() > reader.deadline {
                kill(process.processIdentifier, SIGKILL)
                return XCTFail("probe never printed READY")
            }
        }

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }

    private final class LineReader {
        let process: Process
        private var buffer = Data()
        private(set) var lastLine: String?
        var deadline = Date.distantFuture

        init(process: Process) {
            self.process = process
        }

        private var pipe: Pipe { process.standardOutput as! Pipe }

        func nextLine(deadline: Date) throws -> Bool {
            self.deadline = deadline
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    lastLine = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(..<buffer.index(after: newline))
                    return true
                }
                if Date() > deadline { return false }
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty {
                    if !buffer.isEmpty {
                        lastLine = String(decoding: buffer, as: UTF8.self)
                        buffer.removeAll()
                        return true
                    }
                    return false
                }
                buffer.append(chunk)
            }
        }
    }
}
