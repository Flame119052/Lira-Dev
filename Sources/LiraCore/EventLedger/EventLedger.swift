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
    /// last committed event, or `issues` names exactly what is wrong and
    /// where — including the last sequence up to which every event still
    /// decodes cleanly (the last valid point).
    public struct IntegrityReport: Equatable, Sendable {
        /// Raw SQLite `PRAGMA integrity_check` verdict; `"ok"` when healthy.
        public let sqliteIntegrityCheck: String
        public let eventCount: Int
        public let firstSequence: Int64?
        /// Sequence of the newest event present in storage.
        public let lastStoredSequence: Int64?
        /// Highest sequence such that EVERY event from the beginning up to
        /// and including it fully decodes. The "last valid point" after a
        /// crash or corruption: readers can trust everything up to here.
        public let lastValidSequence: Int64?
        /// Human-readable problems found, empty when healthy. Each names the
        /// offending sequence where one exists.
        public let issues: [String]

        public var isHealthy: Bool {
            sqliteIntegrityCheck == "ok"
                && issues.isEmpty
                && lastValidSequence == lastStoredSequence
        }
    }

    public enum LedgerError: Error, Equatable {
        case invalidEventType(String)
        case invalidPayloadSchemaVersion(Int)
        case payloadIsNotValidJSON
        /// Payload exceeds `maxPayloadBytes` — the ledger bounds per-row size
        /// so no producer (e.g. a runaway model loop) can balloon rows
        /// without bound (audit dimension H).
        case payloadTooLarge(bytes: Int, maxBytes: Int)
        case emptyProvenanceProducer
        case unreadableRow(sequence: Int64, reason: String)
        /// The database contains migrations this build does not know — it was
        /// written by a newer version of Lira. Refuse rather than misread
        /// (the "forward" in forward-only migrations).
        case databaseWrittenByNewerVersion
    }

    /// Upper bound for a single event's JSON payload (1 MiB). Real events are
    /// far smaller; the cap exists so unbounded growth is structurally
    /// impossible per row, not merely unlikely.
    public static let maxPayloadBytes = 1_048_576

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
        if event.payload.count > Self.maxPayloadBytes {
            throw LedgerError.payloadTooLarge(bytes: event.payload.count, maxBytes: Self.maxPayloadBytes)
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
        //
        // recursive_triggers closes an SQLite default-off hole: with it off,
        // INSERT OR REPLACE performs its implicit DELETE without firing the
        // delete trigger, so REPLACE could rewrite history. (The schema also
        // blocks this at table level — see LedgerSchema — this is the
        // connection-level backstop.)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA recursive_triggers = ON")
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
    /// Pass `limit` to bound the read (the app-shell page size); `nil` returns
    /// the full tail. The limit is applied in SQL so a page cannot decode the
    /// entire remaining ledger and then throw most of it away.
    public func events(afterSequence: Int64, limit: Int? = nil) throws -> [CommittedEvent] {
        try pool.read { db in
            let rows: [Row]
            if let limit {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM \(LedgerSchema.tableName) WHERE sequence > ? ORDER BY sequence ASC LIMIT ?",
                    arguments: [afterSequence, limit]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM \(LedgerSchema.tableName) WHERE sequence > ? ORDER BY sequence ASC",
                    arguments: [afterSequence]
                )
            }
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
    /// SQLite-level integrity, sequence contiguity, and — by decoding every
    /// row through the exact same path `allEvents()` uses — whether each
    /// stored event is actually readable. A healthy report means every event
    /// up to `lastValidSequence` is fully intact; if anything is wrong,
    /// `issues` names the offending sequences and `lastValidSequence` marks
    /// the last point readers can trust.
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

            // Decode every row through the read path itself. Whatever
            // verifyIntegrity accepts, allEvents() must be able to read —
            // the two can never disagree about health.
            var lastValidSequence: Int64?
            var sawUnreadable = false
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(LedgerSchema.tableName) ORDER BY sequence ASC"
            )
            for row in rows {
                let sequence: Int64 = row["sequence"]
                do {
                    _ = try Self.committedEvent(fromRow: row)
                    if !sawUnreadable { lastValidSequence = sequence }
                } catch let error as LedgerError {
                    sawUnreadable = true
                    switch error {
                    case let .unreadableRow(_, reason):
                        issues.append("sequence \(sequence) is unreadable: \(reason)")
                    default:
                        issues.append("sequence \(sequence) is unreadable")
                    }
                } catch {
                    sawUnreadable = true
                    issues.append("sequence \(sequence) is unreadable: \(error)")
                }
            }

            return IntegrityReport(
                sqliteIntegrityCheck: sqliteVerdict,
                eventCount: count,
                firstSequence: lo,
                lastStoredSequence: hi,
                lastValidSequence: lastValidSequence,
                issues: issues
            )
        }
    }

    // MARK: - Row decoding

    /// Decodes a stored row into the envelope, enforcing the FULL envelope
    /// contract on read — the same rules append-time validation applies.
    /// This is what makes `verifyIntegrity()` and `allEvents()` incapable of
    /// disagreeing about health: whatever this accepts is fully valid.
    ///
    /// Every column decodes through GRDB's *failable* converters. A plain
    /// typed cast (`row["x"] as Date`) traps via internal `try!` when a raw
    /// SQL connection has poisoned the column — a trap would crash reads
    /// AND the integrity verifier itself; here any malformation becomes a
    /// reportable `unreadableRow` instead (R2 audit finding).
    private static func committedEvent(fromRow row: Row) throws -> CommittedEvent {
        let sequence: Int64 = row["sequence"]

        func unreadable(_ reason: String) -> LedgerError {
            .unreadableRow(sequence: sequence, reason: reason)
        }
        func text(_ column: String) throws -> String {
            guard let value = String.fromDatabaseValue(row[column]) else {
                throw unreadable("\(column) is not text")
            }
            return value
        }

        let eventIDText = try text("event_id")
        guard let eventID = UUID(uuidString: eventIDText) else {
            throw unreadable("event_id is not a UUID")
        }
        let aggregateKindText = try text("aggregate_kind")
        guard let aggregateKind = AggregateKind(rawValue: aggregateKindText) else {
            throw unreadable("unknown aggregate_kind '\(aggregateKindText)'")
        }
        let aggregateIDText = try text("aggregate_id")
        guard let aggregateID = UUID(uuidString: aggregateIDText) else {
            throw unreadable("aggregate_id is not a UUID")
        }
        let eventType = try text("event_type")
        if eventType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw unreadable("event_type is empty or whitespace")
        }
        let schemaVersion: Int64 = row["payload_schema_version"]
        if schemaVersion < 1 {
            throw unreadable("payload_schema_version \(schemaVersion) is below 1")
        }
        guard let occurredAt = Date.fromDatabaseValue(row["occurred_at"]) else {
            throw unreadable("occurred_at is not a parseable timestamp")
        }
        let provenanceText = try text("provenance")
        guard let provenanceData = provenanceText.data(using: .utf8),
              let provenance = try? JSONDecoder().decode(EventProvenance.self, from: provenanceData)
        else {
            throw unreadable("provenance does not decode")
        }
        if provenance.producer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw unreadable("provenance.producer is empty or whitespace")
        }

        return CommittedEvent(
            sequence: sequence,
            eventID: eventID,
            aggregateKind: aggregateKind,
            aggregateID: aggregateID,
            eventType: eventType,
            payloadSchemaVersion: Int(schemaVersion),
            occurredAt: occurredAt,
            provenance: provenance,
            payload: row["payload"]
        )
    }
}
