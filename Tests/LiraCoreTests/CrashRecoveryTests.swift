import XCTest
@testable import LiraCore

/// Deterministic kill/reopen integrity test (ticket #33): a helper process
/// appends events and reports progress; the test SIGKILLs it mid-write at a
/// known point, reopens the ledger, and verifies that everything up to the
/// last committed event is fully intact — no silent corruption, no torn or
/// reordered events, acknowledged commits never lost.
final class CrashRecoveryTests: XCTestCase {
    func testKillDuringSingleEventAppendsLeavesConsistentPrefix() throws {
        try runKillAndReopen(mode: "single", batchSize: 1, ackAfter: 100)
    }

    /// In batch mode every transaction holds 7 events, so a surviving count
    /// that is not a multiple of 7 would mean a torn batch survived — which
    /// atomicity forbids.
    func testKillMidBatchNeverSurfacesAPartialBatch() throws {
        try runKillAndReopen(mode: "batch", batchSize: 7, ackAfter: 98)
    }

    func testEmptyLedgerVerifiesHealthy() throws {
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let report = try ledger.verifyIntegrity()
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.eventCount, 0)
        XCTAssertNil(report.lastSequence)
    }

    // MARK: - Kill/reopen harness

    private func runKillAndReopen(
        mode: String,
        batchSize: Int,
        ackAfter: Int,
        function: String = #function,
        line: UInt = #line
    ) throws {
        let targetCount = 200
        let url = TestSupport.makeTemporaryDatabaseURL(function: function)

        let process = Process()
        process.executableURL = try CrashProbe.executableURL()
        process.arguments = [
            url.path,
            mode,
            "\(targetCount)",
            "\(batchSize)",
            "\(batchSize > 1 ? batchSize * 3 : 20)", // ack cadence aligned to batches
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Wait until the probe acknowledges `ackAfter` committed events.
        var buffer = Data()
        var acknowledgedLastSequence: Int64?
        let deadline = Date().addingTimeInterval(60)
        while (acknowledgedLastSequence ?? 0) < ackAfter {
            if Date() > deadline {
                kill(process.processIdentifier, SIGKILL)
                return XCTFail("probe never reached \(ackAfter) committed events", file: #filePath, line: line)
            }
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                kill(process.processIdentifier, SIGKILL)
                return XCTFail(
                    "probe exited before reaching \(ackAfter) commits; stderr: \(stderrText)",
                    file: #filePath,
                    line: line
                )
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineText = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(..<buffer.index(after: newline))
                if let sequence = Self.sequence(fromProgressLine: lineText) {
                    acknowledgedLastSequence = sequence
                }
            }
        }

        // Hard kill mid-write. No cleanup, no checkpoint request — exactly a
        // crashed process.
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal, "expected SIGKILL death")

        // Reopen from disk alone.
        let reopened = try EventLedger(databaseURL: url)

        let report = try reopened.verifyIntegrity()
        XCTAssertTrue(report.isHealthy, "ledger unhealthy after crash: \(report)")

        let survivors = try reopened.allEvents()

        // The ledger is consistent up to its last valid point:
        // - contiguous sequences 1...C with C == lastSequence
        // - at least the acknowledged events survived
        guard case let survivorCount = survivors.count else { return }
        XCTAssertEqual(Int64(survivorCount), report.lastSequence ?? 0)
        XCTAssertGreaterThanOrEqual(survivorCount, ackAfter, "acknowledged commits must survive")
        XCTAssertLessThanOrEqual(survivorCount, targetCount)

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
        if batchSize > 1 {
            XCTAssertEqual(survivorCount % batchSize, 0, "a partial batch survived the crash")
        }

        // Recovery is complete: the ledger accepts new appends continuing
        // the sequence without reuse or gaps.
        let appended = try reopened.append(TestSupport.makeEvent(index: -1))
        XCTAssertEqual(appended.sequence, (report.lastSequence ?? 0) + 1)

        let finalReport = try reopened.verifyIntegrity()
        XCTAssertTrue(finalReport.isHealthy)
    }

    private static func sequence(fromProgressLine line: String) -> Int64? {
        guard line.hasPrefix("COMMITTED ") else { return nil }
        return Int64(line.dropFirst("COMMITTED ".count))
    }
}
