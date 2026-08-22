import GRDB
import XCTest
@testable import LiraCore

/// The event envelope is the ledger's contract with every other subsystem:
/// stable unique ID, aggregate identity, monotonic sequence (total order),
/// timestamp, payload schema version, and provenance.
final class EnvelopeAndOrderingTests: XCTestCase {
    func testAppendRoundTripsTheFullEnvelope() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let occurredAt = Date(timeIntervalSince1970: 1_770_000_000.25)
        let provenance = EventProvenance(
            producer: "lira.model",
            modelID: "g9v3-3b-mlx-4bit",
            provider: "local-mlx",
            revision: "rev-2026-08-01"
        )
        let aggregateID = UUID()

        let committed = try EventLedger(databaseURL: url).append(
            TestSupport.makeEvent(
                index: 1,
                aggregateKind: .step,
                aggregateID: aggregateID,
                eventType: "step.completed",
                payloadSchemaVersion: 3,
                occurredAt: occurredAt,
                provenance: provenance
            )
        )

        XCTAssertEqual(committed.sequence, 1)

        let reopened = try EventLedger(databaseURL: url)
        let events = try reopened.allEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(
            events[0].sequence, committed.sequence,
            "sequence assigned at commit must survive reopen"
        )
        XCTAssertEqual(events[0].eventID, committed.eventID)
        XCTAssertEqual(events[0].aggregateKind, .step)
        XCTAssertEqual(events[0].aggregateID, aggregateID)
        XCTAssertEqual(events[0].eventType, "step.completed")
        XCTAssertEqual(events[0].payloadSchemaVersion, 3)
        XCTAssertEqual(events[0].occurredAt, occurredAt)
        XCTAssertEqual(events[0].provenance, provenance)
    }

    func testSequencesAreMonotonicContiguousAndStableAcrossReopens() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)

        _ = try ledger.append(TestSupport.makeEvent(index: 1))
        _ = try ledger.append([
            TestSupport.makeEvent(index: 2),
            TestSupport.makeEvent(index: 3),
            TestSupport.makeEvent(index: 4),
        ])
        _ = try ledger.append(TestSupport.makeEvent(index: 5))

        // Reopen: order and sequences are exactly as written.
        let reopened = try EventLedger(databaseURL: url)
        let events = try reopened.allEvents()
        XCTAssertEqual(events.map(\.probePayloadIndex), [1, 2, 3, 4, 5])
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3, 4, 5])

        // New appends continue the sequence without reuse.
        let appended = try reopened.append(TestSupport.makeEvent(index: 6))
        XCTAssertEqual(appended.sequence, 6)
    }

    func testTotalOrderIsBySequenceEvenWhenTimestampsGoBackwards() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        let base = Date(timeIntervalSince1970: 1_770_000_000)

        // Timestamps deliberately decrease; ordering must not follow them.
        for index in 1...5 {
            _ = try ledger.append(
                TestSupport.makeEvent(index: index, occurredAt: base - TimeInterval(6 - index))
            )
        }

        let events = try ledger.allEvents()
        XCTAssertEqual(events.map(\.probePayloadIndex), [1, 2, 3, 4, 5])
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3, 4, 5])
    }

    func testDuplicateEventIDIsRejectedAndLedgerUnchanged() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        let sharedID = UUID()

        _ = try ledger.append(TestSupport.makeEvent(index: 1, eventID: sharedID))
        XCTAssertThrowsError(
            try ledger.append(TestSupport.makeEvent(index: 2, eventID: sharedID))
        ) { error in
            XCTAssertTrue(error is DatabaseError, "expected constraint error, got \(error)")
        }
        XCTAssertEqual(try ledger.allEvents().count, 1)
    }

    func testEventsCanBeFilteredByAggregate() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        let goalA = UUID()
        let goalB = UUID()

        _ = try ledger.append([
            TestSupport.makeEvent(index: 1, aggregateKind: .goal, aggregateID: goalA),
            TestSupport.makeEvent(index: 2, aggregateKind: .goal, aggregateID: goalB),
            TestSupport.makeEvent(index: 3, aggregateKind: .run, aggregateID: goalA),
        ])

        let eventsForA = try ledger.events(forAggregateID: goalA)
        XCTAssertEqual(eventsForA.map(\.probePayloadIndex), [1, 3])
        XCTAssertEqual(eventsForA.map(\.aggregateKind), [.goal, .run])
    }

    func testPayloadDecodesThroughTheTestSeam() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        _ = try ledger.append(TestSupport.makeEvent(index: 42))

        let decoded = try ledger.allEvents()[0].decodedPayload(as: TestSupport.ProbePayload.self)
        XCTAssertEqual(decoded.index, 42)
    }
}
