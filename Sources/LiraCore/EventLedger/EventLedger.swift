import Foundation
import GRDB

/// The durable core: sole writable owner of Lira's SQLite database, exposing
/// an append-only domain-event ledger (ADR-0006, ADR-0013).
///
/// Every goal, run, step, and effect is recorded here as an immutable event.
/// Nothing outside the ledger maintains authoritative state, which makes
/// reading events back the primary test seam for most of the system
/// (see docs/event-ledger.md).
///
/// Guarantees, all enforced structurally rather than by convention:
/// - **Append-only**: UPDATE/DELETE against event rows are rejected by
///   database triggers, on any connection.
/// - **Atomic appends**: a single event or a batch commits entirely or not
///   at all; readers never see partial batches (WAL snapshot isolation).
/// - **Total order**: `CommittedEvent.sequence` is monotonic across all
///   events ever written and defines the ledger's ordering. Timestamps are
///   informational only.
/// - **Forward-only migrations**: schema changes never rewrite existing
///   event payloads (see `LedgerSchema`).
/// - **Crash safety**: committed events survive process death; partially
///   written transactions are discarded by SQLite recovery, never surfaced
///   as half-events (`verifyIntegrity()` reports the last valid point).
public final class EventLedger: Sendable {
    /// Result of `verifyIntegrity()`: either the ledger is healthy up to its
    /// last committed event, or `issues` names exactly what is wrong.
    public struct IntegrityReport: Equatable, Sendable {
        /// Raw SQLite `PRAGMA integrity_check` verdict; `"ok"` when healthy.
        public let sqliteIntegrityCheck: String
        public let eventCount: Int
        public let firstSequence: Int64?
        /// Sequence of the newest event — the last valid point of the ledger.
        public let lastSequence: Int64?
        /// Human-readable problems found, empty when healthy.
        public let issues: [String]

        public var isHealthy: Bool {
            sqliteIntegrityCheck == "ok" && issues.isEmpty
        }
    }

    public enum LedgerError: Error, Equatable {
        case invalidEventType(String)
        case invalidPayloadSchemaVersion(Int)
        case payloadIsNotValidJSON
        case emptyProvenanceProducer
        case unreadableRow(sequence: Int64, reason: String)
        /// The database contains migrations this build does not know — it was
        /// written by a newer version of Lira. Refuse rather than misread
        /// (the "forward" in forward-only migrations).
        case databaseWrittenByNewerVersion
    }

    /// Validation performed before any write attempt, so malformed envelopes
    /// fail fast without touching the database. The schema carries matching
    /// CHECK constraints (see `LedgerSchema`) as a last line of defense
    /// against any raw SQL connection.
    private static func validate(_ event: PendingEvent) throws {
        if event.eventType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LedgerError.invalidEventType(event.eventType)
        }
        if event.payloadSchemaVersion < 1 {
            throw LedgerError.invalidPayloadSchemaVersion(event.payloadSchemaVersion)
        }
        if (try? JSONSerialization.jsonObject(with: event.payload)) == nil {
            throw LedgerError.payloadIsNotValidJSON
        }
        if event.provenance.producer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LedgerError.emptyProvenanceProducer
        }
    }

    public let databaseURL: URL
    private let pool: DatabasePool

    /// Opens (creating or migrating as needed) the ledger database at the
    /// given URL. Reopening an existing ledger applies no new migrations
    /// when the schema is current, and never touches existing events.
    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL

        var configuration = Configuration()
        configuration.label = "lira.core-event-ledger"
        // Durability over speed: commits are low-frequency (per step/effect,
        // not per token) and must survive power loss, not just process death.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }

        let pool = try DatabasePool(
            path: databaseURL.path,
            configuration: configuration
        )
        self.pool = pool

        let migrator = LedgerSchema.migrator()
        // Refuse files a newer Lira has migrated — never reinterpret events
        // written under an unknown schema version.
        if try pool.read({ try migrator.hasBeenSuperseded($0) }) {
            throw LedgerError.databaseWrittenByNewerVersion
        }
        try migrator.migrate(pool)
    }

    // MARK: - Appending

    /// Appends one event atomically.
    @discardableResult
    public func append(_ event: PendingEvent) throws -> CommittedEvent {
        try append([event])[0]
    }

    /// Appends a batch of events as ONE atomic transaction: every event in
    /// the batch becomes visible together, or none do. This is how callers
    /// record multi-event transactions.
    @discardableResult
    public func append(_ events: [PendingEvent]) throws -> [CommittedEvent] {
        guard !events.isEmpty else { return [] }
        for event in events {
            try Self.validate(event)
        }

        let encoder = JSONEncoder()
        return try pool.write { db in
            var committed: [CommittedEvent] = []
            committed.reserveCapacity(events.count)
            for event in events {
                let provenanceJSON = try encoder.encode(event.provenance)
                try db.execute(
                    sql: """
                        INSERT INTO \(LedgerSchema.tableName)
                            (event_id, aggregate_kind, aggregate_id, event_type,
                             payload_schema_version, occurred_at, provenance, payload)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        event.eventID.uuidString,
                        event.aggregateKind.rawValue,
                        event.aggregateID.uuidString,
                        event.eventType,
                        event.payloadSchemaVersion,
                        event.occurredAt,
                        String(decoding: provenanceJSON, as: UTF8.self),
                        event.payload,
                    ]
                )
                committed.append(
                    CommittedEvent(
                        sequence: db.lastInsertedRowID,
                        eventID: event.eventID,
                        aggregateKind: event.aggregateKind,
                        aggregateID: event.aggregateID,
                        eventType: event.eventType,
                        payloadSchemaVersion: event.payloadSchemaVersion,
                        occurredAt: event.occurredAt,
                        provenance: event.provenance,
                        payload: event.payload
                    )
                )
            }
            return committed
        }
    }

    // MARK: - Reading

    /// All events, oldest first — the canonical way to observe what happened.
    public func allEvents() throws -> [CommittedEvent] {
        try events(afterSequence: 0)
    }

    /// Events with a sequence number strictly greater than `afterSequence`.
    public func events(afterSequence: Int64) throws -> [CommittedEvent] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(LedgerSchema.tableName) WHERE sequence > ? ORDER BY sequence ASC",
                arguments: [afterSequence]
            )
            return try rows.map(Self.committedEvent(fromRow:))
        }
    }

    /// All events for one aggregate, ordered by sequence.
    public func events(forAggregateID aggregateID: UUID) throws -> [CommittedEvent] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(LedgerSchema.tableName) WHERE aggregate_id = ? ORDER BY sequence ASC",
                arguments: [aggregateID.uuidString]
            )
            return try rows.map(Self.committedEvent(fromRow:))
        }
    }

    /// Sequence of the newest committed event, or nil for an empty ledger.
    public func lastCommittedSequence() throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MAX(sequence) FROM \(LedgerSchema.tableName)"
            )
        }
    }

    // MARK: - Integrity

    /// Checks the whole ledger after an unexpected shutdown (or anytime):
    /// SQLite-level integrity, sequence contiguity, and payload/provenance
    /// validity of every row. A healthy report means every event up to
    /// `lastSequence` is fully intact — the "last valid point" after a crash.
    public func verifyIntegrity() throws -> IntegrityReport {
        try pool.read { db in
            let checkLines = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            let sqliteVerdict = checkLines.first ?? "no result"

            var issues: [String] = []
            if sqliteVerdict != "ok" {
                issues.append("sqlite integrity_check: \(checkLines.joined(separator: "; "))")
            }

            let totals = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS n,
                           MIN(sequence) AS lo,
                           MAX(sequence) AS hi,
                           COUNT(DISTINCT event_id) AS distinctIDs,
                           SUM(NOT json_valid(payload)) AS badPayloads,
                           SUM(NOT json_valid(provenance)) AS badProvenance
                    FROM \(LedgerSchema.tableName)
                    """
            )!

            let count: Int = totals["n"]
            let lo: Int64? = totals["lo"]
            let hi: Int64? = totals["hi"]

            if count > 0 {
                if lo != 1 {
                    issues.append("lowest sequence is \(String(describing: lo)), expected 1")
                }
                if let lo, let hi, hi - lo + 1 != Int64(count) {
                    issues.append("sequence gap: count=\(count) range=\(lo)...\(hi)")
                }
            } else if lo != nil || hi != nil {
                issues.append("count is zero but sequence bounds exist")
            }

            let distinctIDs: Int = totals["distinctIDs"]
            if distinctIDs != count {
                issues.append("duplicate event IDs: \(count - distinctIDs)")
            }

            let badPayloads: Int64 = totals["badPayloads"] ?? 0
            if badPayloads > 0 {
                issues.append("\(badPayloads) row(s) with invalid payload JSON")
            }
            let badProvenance: Int64 = totals["badProvenance"] ?? 0
            if badProvenance > 0 {
                issues.append("\(badProvenance) row(s) with invalid provenance JSON")
            }

            return IntegrityReport(
                sqliteIntegrityCheck: sqliteVerdict,
                eventCount: count,
                firstSequence: lo,
                lastSequence: hi,
                issues: issues
            )
        }
    }

    // MARK: - Row decoding

    private static func committedEvent(fromRow row: Row) throws -> CommittedEvent {
        let sequence: Int64 = row["sequence"]

        func unreadable(_ reason: String) -> LedgerError {
            .unreadableRow(sequence: sequence, reason: reason)
        }

        guard let eventID = UUID(uuidString: row["event_id"]) else {
            throw unreadable("event_id is not a UUID")
        }
        guard let aggregateKind = AggregateKind(rawValue: row["aggregate_kind"]) else {
            throw unreadable("unknown aggregate_kind '\(row["aggregate_kind"] as String)'")
        }
        guard let aggregateID = UUID(uuidString: row["aggregate_id"]) else {
            throw unreadable("aggregate_id is not a UUID")
        }
        let occurredAt: Date = row["occurred_at"]
        guard let provenance = try? JSONDecoder().decode(
            EventProvenance.self,
            from: Data((row["provenance"] as String).utf8)
        ) else {
            throw unreadable("provenance does not decode")
        }

        return CommittedEvent(
            sequence: sequence,
            eventID: eventID,
            aggregateKind: aggregateKind,
            aggregateID: aggregateID,
            eventType: row["event_type"],
            payloadSchemaVersion: row["payload_schema_version"],
            occurredAt: occurredAt,
            provenance: provenance,
            payload: row["payload"]
        )
    }
}
