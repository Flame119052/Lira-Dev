import GRDB
import XCTest
@testable import LiraCore

/// Append-only must hold against ANY SQLite connection — not just Lira's own
/// API. These tests open independent raw connections and try to rewrite or
/// remove history; the database itself must reject them.
final class AppendOnlyTests: XCTestCase {
    func testUpdateIsRejectedOnIndependentRawConnection() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        _ = try ledger.append(TestSupport.makeEvent(index: 1))

        let intruder = try DatabaseQueue(path: url.path)
        XCTAssertThrowsError(
            try intruder.write { db in
                try db.execute(
                    sql: "UPDATE \(LedgerSchema.tableName) SET event_type = 'tampered'"
                )
            }
        ) { error in
            guard let databaseError = error as? DatabaseError else {
                return XCTFail("expected DatabaseError, got \(error)")
            }
            XCTAssertEqual(databaseError.resultCode, .SQLITE_CONSTRAINT)
            XCTAssertTrue(
                databaseError.message?.contains("append-only") ?? false,
                "rejection message should name the invariant: \(databaseError.message ?? "nil")"
            )
        }

        // Nothing was rewritten.
        XCTAssertEqual(try ledger.allEvents()[0].eventType, "goal.created")
    }

    func testDeleteIsRejectedOnIndependentRawConnection() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        _ = try ledger.append(TestSupport.makeEvent(index: 1))

        let intruder = try DatabaseQueue(path: url.path)
        XCTAssertThrowsError(
            try intruder.write { db in
                try db.execute(sql: "DELETE FROM \(LedgerSchema.tableName)")
            }
        ) { error in
            guard let databaseError = error as? DatabaseError else {
                return XCTFail("expected DatabaseError, got \(error)")
            }
            XCTAssertEqual(databaseError.resultCode, .SQLITE_CONSTRAINT)
            XCTAssertTrue(databaseError.message?.contains("append-only") ?? false)
        }

        XCTAssertEqual(try ledger.allEvents().count, 1)
    }

    func testTriggersSurviveReopenAndStillRejectWrites() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        _ = try EventLedger(databaseURL: url).append(TestSupport.makeEvent(index: 1))

        // Fresh instance on the same file: triggers were created inside the
        // migration, so they are part of the stored schema.
        let reopened = try EventLedger(databaseURL: url)
        let raw = try DatabaseQueue(path: url.path)

        for statement in [
            "UPDATE \(LedgerSchema.tableName) SET aggregate_kind = 'run'",
            "DELETE FROM \(LedgerSchema.tableName) WHERE sequence = 1",
        ] {
            XCTAssertThrowsError(try raw.write { try $0.execute(sql: statement) }) { error in
                guard let databaseError = error as? DatabaseError else {
                    return XCTFail("expected DatabaseError for \(statement), got \(error)")
                }
                XCTAssertEqual(databaseError.resultCode, .SQLITE_CONSTRAINT, "statement: \(statement)")
            }
        }

        XCTAssertEqual(try reopened.allEvents().count, 1)
    }

    func testAppendOnlyDoesNotBlockAppends() throws {
        // Sanity: the enforcement is not over-broad — writes of new rows work.
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        for index in 1...3 {
            XCTAssertEqual(try ledger.append(TestSupport.makeEvent(index: index)).sequence, Int64(index))
        }
        XCTAssertEqual(try ledger.allEvents().count, 3)
    }

    /// The schema's CHECK constraints backstop Swift-side validation for raw
    /// SQL connections too.
    func testSchemaChecksRejectMalformedRowsFromRawConnection() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)

        let intruder = try DatabaseQueue(path: url.path)
        func insert(withPayload payload: String, provenance: String) throws {
            try intruder.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO \(LedgerSchema.tableName)
                            (event_id, aggregate_kind, aggregate_id, event_type,
                             payload_schema_version, occurred_at, provenance, payload)
                        VALUES (?, 'goal', ?, 'goal.created', 1,
                                '2026-01-01 00:00:00.000', ?, ?)
                        """,
                    arguments: [UUID().uuidString, UUID().uuidString, provenance, Data(payload.utf8)]
                )
            }
        }

        // Payload that is not JSON.
        XCTAssertThrowsError(try insert(withPayload: "not json", provenance: "{}")) { assertConstraint($0) }
        // Provenance without a non-empty producer field.
        XCTAssertThrowsError(try insert(withPayload: "{}", provenance: "{}")) { assertConstraint($0) }
        // Zero schema version.
        XCTAssertThrowsError(
            try intruder.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO \(LedgerSchema.tableName)
                            (event_id, aggregate_kind, aggregate_id, event_type,
                             payload_schema_version, occurred_at, provenance, payload)
                        VALUES (?, 'goal', ?, 'goal.created', 0,
                                '2026-01-01 00:00:00.000', '{"producer":"test"}', '{}')
                        """,
                    arguments: [UUID().uuidString, UUID().uuidString]
                )
            }
        ) { assertConstraint($0) }

        XCTAssertEqual(try ledger.allEvents().count, 0)
    }

    private func assertConstraint(_ error: Error) {
        guard let databaseError = error as? DatabaseError else {
            return XCTFail("expected DatabaseError, got \(error)")
        }
        XCTAssertEqual(databaseError.resultCode, .SQLITE_CONSTRAINT)
    }
}
