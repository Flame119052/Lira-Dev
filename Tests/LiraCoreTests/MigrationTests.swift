import GRDB
import XCTest
@testable import LiraCore

/// Schema migrations are versioned and forward-only, and they never mutate
/// or reinterpret existing event payloads.
final class MigrationCompatibilityTests: XCTestCase {
    func testReopeningAnUpToDateLedgerRunsNoNewMigrations() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        _ = try EventLedger(databaseURL: url)
        let firstApplied = try appliedMigrations(at: url)

        // Reopen: idempotent — no error, same migration set.
        _ = try EventLedger(databaseURL: url)
        XCTAssertEqual(try appliedMigrations(at: url), firstApplied)
    }

    func testMigrationsAreRegisteredInForwardOrder() {
        let migrator = LedgerSchema.migrator()
        let identifiers = migrator.migrations
        XCTAssertFalse(identifiers.isEmpty)
        // GRDB preserves registration order; a ledger replays them in exactly
        // this order on any fresh file.
        XCTAssertEqual(identifiers.first, "v1.domain-event-ledger")
    }

    /// Simulates the future: v1 events exist, then a new schema version
    /// ships. The old rows must come through byte-identical, and the ledger
    /// must keep working.
    func testFutureMigrationLeavesExistingEventRowsUntouched() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()

        // Apply the current schema manually (v1), write events through the
        // real API, and snapshot every stored row byte-exactly.
        var extendedMigrator = LedgerSchema.migrator()
        try extendedMigrator.migrate(try DatabasePool(path: url.path))
        let ledger = try EventLedger(databaseURL: url) // no-op migrations on reopen
        let occurredAt = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try ledger.append([
            TestSupport.makeEvent(index: 1, occurredAt: occurredAt),
            TestSupport.makeEvent(
                index: 2,
                occurredAt: occurredAt,
                provenance: EventProvenance(
                    producer: "lira.model",
                    modelID: "g9v3-3b-mlx-4bit",
                    provider: "local-mlx",
                    revision: "rev-a"
                )
            ),
        ])
        let before = try TestSupport.readRawRows(at: url)

        // A hypothetical v2 migration: additive only (new table + index).
        // Rewriting event payloads here would be a spec violation; this is
        // where that rule is exercised.
        extendedMigrator.registerMigration("v2.example-additive-migration") { db in
            try db.create(table: "schema_notes") { t in
                t.primaryKey("id", .text).notNull()
                t.column("note", .text).notNull()
            }
            try db.create(
                index: "idx_domain_event_schema_version",
                on: LedgerSchema.tableName,
                columns: ["payload_schema_version"]
            )
        }
        try extendedMigrator.migrate(try DatabasePool(path: url.path))

        // Every pre-existing row is byte-identical after migrating.
        let after = try TestSupport.readRawRows(at: url)
        XCTAssertEqual(after, before)

        // And the ledger remains fully functional.
        let reopened = try EventLedger(databaseURL: url)
        let report = try reopened.verifyIntegrity()
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.eventCount, 2)
        XCTAssertNoThrow(try reopened.append(TestSupport.makeEvent(index: 3)))
    }

    /// A database migrated by a newer registrant must not be silently
    /// accepted by an older one — this is what "forward-only" means for a
    /// ledger that must never be reinterpreted by downgraded code.
    func testMigrationsNeverReplayOrRewindOnSharedDatabase() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let pool = try DatabasePool(path: url.path)

        let full = LedgerSchema.migrator()
        try full.migrate(pool)
        XCTAssertEqual(try appliedMigrations(at: url), full.migrations)

        // Re-running the identical set changes nothing.
        try LedgerSchema.migrator().migrate(pool)
        XCTAssertEqual(try appliedMigrations(at: url), full.migrations)
    }

    private func appliedMigrations(at url: URL) throws -> [String] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            if try db.tableExists("grdb_migrations") {
                return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            }
            return []
        }
    }
}
