import Foundation

/// The kind of aggregate an event belongs to.
///
/// The ledger's known aggregate shapes: every durable thing Lira records
/// hangs off one of these. Enforced in Swift at compile time rather than by
/// a SQLite CHECK constraint, so adding an aggregate kind later is a code
/// change and not a table-rebuild migration.
public enum AggregateKind: String, Codable, CaseIterable, Sendable {
    case goal
    case run
    case step
    case effect
}

/// What produced an event: model/provider/revision where applicable
/// (ADR-0006, ADR-0013). A claim recorded here is never treated as evidence
/// of completion by itself — it names the source so later verification can
/// be traced back to it.
public struct EventProvenance: Codable, Equatable, Sendable {
    /// Required, non-empty. The kind of producer, e.g. `"system"`, `"owner"`,
    /// `"lira.model"` — free-form so new producer kinds don't need migrations.
    public var producer: String
    /// Which model produced the event, e.g. `"g9v3-3b-mlx-4bit"`, if any.
    public var modelID: String?
    /// Which provider served that model, e.g. `"local-mlx"`, `"opencode-go"`, if any.
    public var provider: String?
    /// Model or producing-component revision, if applicable.
    public var revision: String?

    public init(
        producer: String,
        modelID: String? = nil,
        provider: String? = nil,
        revision: String? = nil
    ) {
        self.producer = producer
        self.modelID = modelID
        self.provider = provider
        self.revision = revision
    }
}

/// An event submitted for append. Carries everything except the sequence
/// number, which the ledger assigns atomically at commit time. Timestamps
/// are informational only — total order is defined solely by `sequence`.
public struct PendingEvent: Sendable {
    /// Stable unique identity, assigned by the caller. Appending two events
    /// with the same ID is rejected: it signals a caller bug, not idempotency.
    public let eventID: UUID
    public let aggregateKind: AggregateKind
    public let aggregateID: UUID
    /// Discriminator of what happened within the aggregate, e.g. `"goal.created"`.
    public let eventType: String
    /// Version of this event's payload schema. Payloads are opaque JSON to
    /// the ledger; readers use this version to interpret them.
    public let payloadSchemaVersion: Int
    /// Wall-clock commit time (informational).
    public let occurredAt: Date
    public let provenance: EventProvenance
    /// JSON-encoded payload bytes. Must be valid JSON.
    public let payload: Data

    public init(
        eventID: UUID = UUID(),
        aggregateKind: AggregateKind,
        aggregateID: UUID,
        eventType: String,
        payloadSchemaVersion: Int,
        occurredAt: Date = Date(),
        provenance: EventProvenance,
        payload: Data
    ) {
        self.eventID = eventID
        self.aggregateKind = aggregateKind
        self.aggregateID = aggregateID
        self.eventType = eventType
        self.payloadSchemaVersion = payloadSchemaVersion
        self.occurredAt = occurredAt
        self.provenance = provenance
        self.payload = payload
    }
}

/// An event as committed to the ledger: the pending envelope enriched with
/// the monotonic sequence number that establishes total order across all
/// events. Immutable once written — append-only is enforced by the database,
/// not just convention (ADR-0006).
public struct CommittedEvent: Equatable, Sendable {
    /// Strictly increasing across all events ever committed. Defines total order.
    public let sequence: Int64
    public let eventID: UUID
    public let aggregateKind: AggregateKind
    public let aggregateID: UUID
    public let eventType: String
    public let payloadSchemaVersion: Int
    public let occurredAt: Date
    public let provenance: EventProvenance
    public let payload: Data

    /// Decodes the opaque JSON payload into a typed value. This is how most
    /// behavior tests assert outcomes — by reading events back from the
    /// ledger (the primary test seam, see docs/event-ledger.md).
    public func decodedPayload<T: Decodable>(
        as type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        try decoder.decode(T.self, from: payload)
    }
}
