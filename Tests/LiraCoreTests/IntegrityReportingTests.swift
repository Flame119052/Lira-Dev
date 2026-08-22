import GRDB
import XCTest
@testable import LiraCore

/// The unhealthy path of `verifyIntegrity()`: a ledger that a raw SQL
/// connection has poisoned (in ways that pass the schema's own CHECKs) must
/// be reported as exactly that — with the offending sequence named and a
/// correct last valid point — never silently healthy while reads fail.
final class IntegrityReportingTests: XCTestCase {
    func testUnreadableRowIsReportedWithLastValidPoint() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        _ = try ledger.append(TestSupport.makeEvent(index: 1))
        _ = try ledger.append(TestSupport.makeEvent(index: 2))

        // Poison row 3: passes every schema CHECK (the UUID shape of
        // event_id is not a DB constraint), but the read path must reject it.
        let intruder = try DatabaseQueue(path: url.path)
        try intruder.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(LedgerSchema.tableName)
                        (event_id, aggregate_kind, aggregate_id, event_type,
                         payload_schema_version, occurred_at, provenance, payload)
                    VALUES ('not-a-uuid', 'goal', ?, 'goal.created', 1,
                            '2026-01-01 00:00:00.000', '{"producer":"test"}', '{"index":3}')
                    """,
                arguments: [UUID().uuidString]
            )
        }

        let report = try EventLedger(databaseURL: url).verifyIntegrity()

        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.eventCount, 3)
        XCTAssertEqual(report.lastStoredSequence, 3)
        XCTAssertEqual(report.lastValidSequence, 2, "last valid point is before the poisoned row")
        XCTAssertTrue(
            report.issues.contains { $0.contains("sequence 3") && $0.contains("unreadable") },
            "issues should name the unreadable sequence: \(report.issues)"
        )

        // And the divergence integrity exists to prevent is real: reading
        // fails at exactly that row.
        XCTAssertThrowsError(try ledger.allEvents()) { error in
            XCTAssertEqual(
                error as? EventLedger.LedgerError,
                .unreadableRow(sequence: 3, reason: "event_id is not a UUID")
            )
        }
    }
}
