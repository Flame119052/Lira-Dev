import XCTest
@testable import LiraCore

/// Deterministic kill/reopen integrity tests (ticket #33): a helper process
/// appends events and reports progress; the test SIGKILLs it at known points,
/// reopens the ledger, and verifies that everything up to the last committed
/// event is fully intact — no silent corruption, no torn or reordered events,
/// acknowledged commits never lost, uncommitted transactions discarded whole.
final class CrashRecoveryTests: XCTestCase {
    func testKillBetweenCommitsLeavesConsistentPrefix() throws {
        try runAckThenKill(mode: .single(targetCount: 200, ackEvery: 20), ackAfter: 100)
    }

    /// Every transaction holds 7 events, so a surviving count that is not a
    /// multiple of 7 would mean a torn batch survived — which atomicity forbids.
    func testKillMidGroupingNeverSurfacesAPartialBatch() throws {
        try runAckThenKill(
            mode: .batch(batchSize: 7, groups: 29, ackEveryGroups: 3),
            ackAfter: 98
        )
    }

    /// Kills while a transaction is provably still open: the probe commits a
    /// known prefix, then opens one more transaction, inserts a final batch
    /// WITHOUT committing, prints READY, and sleeps. Killing on READY means
    /// the SIGKILL lands inside a live write — the exact torn-write scenario.
    func testKillInsideOpenTransactionDiscardsUncommittedRows() throws {
        let batchSize = 5
        let groups = 4
        let expectedSurvivors = batchSize * groups // all groups committed pre-torn-phase

        let url = TestSupport.makeTemporaryDatabaseURL()
        let process = try startProbe(url, arguments: [
            url.path,
            "batch",
            "\(batchSize)",
            "\(groups)",
            "1", // acknowledge every group so the prefix is fully printed
        ])

        // Wait until the probe is holding the uncommitted transaction open.
        let lineReader = ProbeLineReader(process: process)
        var sawReady = false
        while !sawReady {
            guard try lineReader.nextLine(deadline: .now + 60) else {
                kill(process.processIdentifier, SIGKILL)
                return XCTFail("probe exited before reaching its torn phase")
            }
            sawReady = (lineReader.lastLine == "READY")
            if !sawReady && Date() > lineReader.deadline {
                kill(process.processIdentifier, SIGKILL)
                return XCTFail("probe never reached its torn phase")
            }
        }

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)

        // Reopen from disk alone: the uncommitted batch must be gone, the
        // committed prefix untouched.
        let reopened = try EventLedger(databaseURL: url)
        let report = try reopened.verifyIntegrity()
        XCTAssertTrue(report.isHealthy, "ledger unhealthy after mid-write kill: \(report)")

        let survivors = try reopened.allEvents()
        XCTAssertEqual(survivors.count, expectedSurvivors)
        XCTAssertEqual(survivors.count % batchSize, 0, "a partial batch survived")
        XCTAssertEqual(survivors.map(\.sequence), Array(1...Int64(expectedSurvivors)))
        for event in survivors {
            XCTAssertEqual(
                try event.decodedPayload(as: TestSupport.ProbePayload.self).index,
                Int(event.sequence)
            )
        }

        // Recovery is complete: appends continue the sequence without reuse.
        let appended = try reopened.append(TestSupport.makeEvent(index: -1))
        XCTAssertEqual(appended.sequence, Int64(expectedSurvivors + 1))
    }

    func testEmptyLedgerVerifiesHealthy() throws {
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let report = try ledger.verifyIntegrity()
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.eventCount, 0)
        XCTAssertNil(report.lastStoredSequence)
        XCTAssertNil(report.lastValidSequence)
    }

    // MARK: - Kill/reopen harness

    private enum ProbeMode {
        case single(targetCount: Int, ackEvery: Int)
        case batch(batchSize: Int, groups: Int, ackEveryGroups: Int)

        var arguments: [String] {
            switch self {
            case let .single(targetCount, ackEvery):
                return ["single", "\(targetCount)", "\(ackEvery)"]
            case let .batch(batchSize, groups, ackEveryGroups):
                return ["batch", "\(batchSize)", "\(groups)", "\(ackEveryGroups)"]
            }
        }
    }

    private func runAckThenKill(
        mode: ProbeMode,
        ackAfter: Int,
        function: String = #function
    ) throws {
        let targetCeiling = switch mode {
        case let .single(targetCount, _): targetCount
        case let .batch(_, groups, _): groups * 1000 // batches are bounded by groups
        }
        let url = TestSupport.makeTemporaryDatabaseURL(function: function)
        let process = try startProbe(url, arguments: [url.path] + mode.arguments)

        // Wait until the probe acknowledges `ackAfter` committed events.
        let lineReader = ProbeLineReader(process: process)
        var acknowledgedLastSequence: Int64?
        while (acknowledgedLastSequence ?? 0) < ackAfter {
            guard try lineReader.nextLine(deadline: .now + 60) else {
                kill(process.processIdentifier, SIGKILL)
                return XCTFail("probe exited before reaching \(ackAfter) committed events")
            }
            if let sequence = Self.sequence(fromProgressLine: lineReader.lastLine ?? "") {
                acknowledgedLastSequence = sequence
            }
            if Date() > lineReader.deadline {
                kill(process.processIdentifier, SIGKILL)
                return XCTFail("probe never reached \(ackAfter) committed events")
            }
        }

        // Hard kill between commits. No cleanup, no checkpoint request —
        // exactly a crashed process.
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal, "expected SIGKILL death")

        // Reopen from disk alone.
        let reopened = try EventLedger(databaseURL: url)

        let report = try reopened.verifyIntegrity()
        XCTAssertTrue(report.isHealthy, "ledger unhealthy after crash: \(report)")

        let survivors = try reopened.allEvents()
        let survivorCount = survivors.count

        // The ledger is consistent up to its last valid point:
        // - contiguous sequences 1...C with C == lastStoredSequence
        // - at least the acknowledged events survived
        XCTAssertEqual(Int64(survivorCount), report.lastStoredSequence ?? 0)
        XCTAssertEqual(report.lastValidSequence, report.lastStoredSequence)
        XCTAssertGreaterThanOrEqual(survivorCount, ackAfter, "acknowledged commits must survive")
        XCTAssertLessThanOrEqual(survivorCount, targetCeiling)

        // Every survivor is fully intact: payload content matches position,
        // IDs unique — no torn rows, no reordering.
        for event in survivors {
            XCTAssertEqual(
                try event.decodedPayload(as: TestSupport.ProbePayload.self).index,
                Int(event.sequence),
                "event \(event.sequence) does not match its written position"
            )
        }
        XCTAssertEqual(Set(survivors.map(\.eventID)).count, survivorCount)

        // Batch transactions are indivisible even under SIGKILL.
        if case let .batch(batchSize, _, _) = mode {
            XCTAssertEqual(survivorCount % batchSize, 0, "a partial batch survived the crash")
        }

        // Recovery is complete: the ledger accepts new appends continuing
        // the sequence without reuse or gaps.
        let appended = try reopened.append(TestSupport.makeEvent(index: -1))
        XCTAssertEqual(appended.sequence, (report.lastStoredSequence ?? 0) + 1)

        let finalReport = try reopened.verifyIntegrity()
        XCTAssertTrue(finalReport.isHealthy)
    }

    // MARK: - Process plumbing

    private func startProbe(_ url: URL, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = try CrashProbe.executableURL()
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return process
    }

    /// Line reader with a buffer that persists across calls, so bytes that
    /// arrive in the same chunk as an earlier line are never discarded.
    private final class ProbeLineReader {
        let process: Process
        private var buffer = Data()

        private(set) var lastLine: String?
        var deadline = Date.distantFuture

        init(process: Process) {
            self.process = process
        }

        private var pipe: Pipe { process.standardOutput as! Pipe }

        /// Blocks until one full line is available. Returns false on EOF or
        /// once `deadline` has passed.
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
                    // EOF: surface any trailing partial line, then stop.
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

    private static func sequence(fromProgressLine line: String) -> Int64? {
        guard line.hasPrefix("COMMITTED ") else { return nil }
        return Int64(line.dropFirst("COMMITTED ".count))
    }
}
