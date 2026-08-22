import Foundation
import GRDB

/// The ledger's database schema: versioned migrations, forward-only.
///
/// Rules every future migration must keep:
/// - Migrations only ever move forward (GRDB's `DatabaseMigrator` enforces
///   this structurally — it refuses databases whose applied migrations are
///   not a prefix of the registered ones).
/// - A migration never mutates or reinterprets existing event rows. New
///   columns/tables/indexes are fine; rewriting payloads is not.
enum LedgerSchema {
    static let tableName = "domain_event"

    /// Fresh migrator each call; registering the same set on the same
    /// database file is idempotent, so reopening a store never re-runs them.
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1 — initial schema. Every database starts here from birth, which
        // is what makes DB-level enforcement universal.
        migrator.registerMigration("v1.domain-event-ledger") { db in
            try db.create(table: tableName) { t in
                // Monotonic sequence number. AUTOINCREMENT additionally
                // guarantees values are never reused even if rows could be
                // removed (they cannot — see triggers below).
                t.autoIncrementedPrimaryKey("sequence")
                t.column("event_id", .text).notNull().unique()
                t.column("aggregate_kind", .text).notNull()
                t.column("aggregate_id", .text).notNull()
                t.column("event_type", .text).notNull()
                t.column("payload_schema_version", .integer).notNull()
                t.column("occurred_at", .datetime).notNull()
                t.column("provenance", .text).notNull()
                t.column("payload", .blob).notNull()

                // Last line of defense behind EventLedger's Swift-side
                // validation: malformed envelopes are rejected even by raw
                // SQL connections.
                t.check(sql: "length(event_type) > 0")
                t.check(sql: "payload_schema_version >= 1")
                t.check(sql: "json_valid(payload)")
                t.check(sql: "json_valid(provenance)")
                t.check(
                    sql: """
                        json_extract(provenance, '$.producer') IS NOT NULL
                        AND length(json_extract(provenance, '$.producer')) > 0
                        """
                )
            }

            try db.create(
                index: "idx_domain_event_aggregate",
                on: tableName,
                columns: ["aggregate_id", "sequence"]
            )
            try db.create(
                index: "idx_domain_event_type",
                on: tableName,
                columns: ["event_type"]
            )

            // Append-only, enforced by the database itself: any UPDATE or
            // DELETE against event rows aborts the statement, regardless of
            // which connection issues it.
            try db.execute(sql: """
                CREATE TRIGGER domain_event_no_update
                BEFORE UPDATE ON \(tableName)
                BEGIN
                    SELECT RAISE(ABORT, 'domain_event is append-only: UPDATE rejected');
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER domain_event_no_delete
                BEFORE DELETE ON \(tableName)
                BEGIN
                    SELECT RAISE(ABORT, 'domain_event is append-only: DELETE rejected');
                END;
                """)
        }

        return migrator
    }
}
