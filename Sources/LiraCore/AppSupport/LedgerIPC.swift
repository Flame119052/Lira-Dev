import Foundation

/// JSON request/response over ticket-2 `IPCClient.send`. Additive ops only —
/// #37 can add new `op` values without renaming `listEvents`.
public enum LedgerIPC {
    public static let listEventsOp = "listEvents"
    public static let defaultLimit = 100
    public static let maxLimit = 200

    public static func encodeListEvents(
        afterSequence: Int64,
        limit: Int = defaultLimit,
        tail: Bool = false
    ) throws -> Data {
        try encoder.encode(
            LedgerIPCRequest(
                op: listEventsOp,
                afterSequence: afterSequence,
                limit: limit,
                tail: tail ? true : nil
            )
        )
    }

    public static func decodeResponse(_ data: Data) throws -> LedgerIPCResponse {
        try decoder.decode(LedgerIPCResponse.self, from: data)
    }

    /// Never throws to the socket handler: a ledger read failure becomes
    /// `{ok:false, error:ledgerUnavailable}` so the UI can show an error
    /// without dropping the session.
    public static func handle(_ data: Data, ledger: EventLedger) -> Data {
        do {
            let request = try decoder.decode(LedgerIPCRequest.self, from: data)
            guard request.op == listEventsOp else {
                return encodeError("unknownOp")
            }
            let limit = clampLimit(request.limit)
            let after: Int64
            if request.tail == true {
                let last = try ledger.lastCommittedSequence() ?? 0
                after = max(0, last - Int64(limit))
            } else {
                after = request.afterSequence ?? 0
            }
            let batch = try ledger.events(afterSequence: after, limit: limit)
            let response = LedgerIPCResponse(
                ok: true,
                events: batch.map(LedgerEventSummary.init(event:)),
                reachedEnd: request.tail == true || batch.count < limit,
                error: nil
            )
            return try encoder.encode(response)
        } catch {
            return encodeError("ledgerUnavailable")
        }
    }

    private static func clampLimit(_ requested: Int?) -> Int {
        min(max(requested ?? defaultLimit, 1), maxLimit)
    }

    private static func encodeError(_ code: String) -> Data {
        (try? encoder.encode(
            LedgerIPCResponse(ok: false, events: nil, reachedEnd: nil, error: code)
        )) ?? Data(#"{"ok":false,"error":"ledgerUnavailable"}"#.utf8)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public struct LedgerIPCRequest: Codable, Sendable, Equatable {
    public var op: String
    public var afterSequence: Int64?
    public var limit: Int?
    /// When true, return the latest `limit` events (still ascending). Additive;
    /// omitted means page forward from `afterSequence`.
    public var tail: Bool?
}

public struct LedgerIPCResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var events: [LedgerEventSummary]
    public var reachedEnd: Bool
    public var error: String?

    public init(
        ok: Bool,
        events: [LedgerEventSummary]?,
        reachedEnd: Bool?,
        error: String?
    ) {
        self.ok = ok
        self.events = events ?? []
        self.reachedEnd = reachedEnd ?? true
        self.error = error
    }
}

/// Wire summary for the event log. No payload bytes — a 1 MiB payload cannot
/// fit in a 1 MiB IPC frame with envelope fields. Additive fields only.
public struct LedgerEventSummary: Codable, Sendable, Equatable {
    public var sequence: Int64
    public var eventID: UUID
    public var aggregateKind: AggregateKind
    public var aggregateID: UUID
    public var eventType: String
    public var occurredAt: Date
    public var producer: String

    public init(event: CommittedEvent) {
        sequence = event.sequence
        eventID = event.eventID
        aggregateKind = event.aggregateKind
        aggregateID = event.aggregateID
        eventType = event.eventType
        occurredAt = event.occurredAt
        producer = event.provenance.producer
    }
}
