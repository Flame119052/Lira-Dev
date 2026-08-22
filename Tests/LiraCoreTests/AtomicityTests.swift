import GRDB
import XCTest
@testable import LiraCore

/// A single event, or a defined multi-event transaction (a batch), commits
/// or fails as a whole. Readers never observe partial writes.
final class AtomicityTests: XCTestCase {
    func testBatchCommitsAllOrNothingOnSuccess() throws {
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())

        let committed = try ledger.append((1...5).map { TestSupport.makeEvent(index: $0) })

        XCTAssertEqual(committed.map(\.sequence), [1, 2, 3, 4, 5], "batch members get consecutive sequences")
        XCTAssertEqual(try ledger.allEvents().count, 5)
    }

    func testFailureMidBatchRollsBackEntireBatch() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        let preexistingID = try ledger.append(TestSupport.makeEvent(index: 0)).eventID

        // Second event of the batch collides with an already-committed ID:
        // the UNIQUE constraint fires after earlier inserts of this batch.
        let batch = [
            TestSupport.makeEvent(index: 1),
            TestSupport.makeEvent(index: 2),
            TestSupport.makeEvent(index: 3, eventID: preexistingID),
            TestSupport.makeEvent(index: 4),
        ]

        XCTAssertThrowsError(try ledger.append(batch)) { error in
            XCTAssertTrue(error is DatabaseError, "expected constraint error, got \(error)")
        }

        // No partial batch: only the pre-existing event remains, and its
        // sequence is untouched — rolled-back inserts must not consume or
        // disturb sequence numbers.
        let events = try ledger.allEvents()
        XCTAssertEqual(events.map(\.probePayloadIndex), [0])
        XCTAssertEqual(events.map(\.sequence), [1])

        // The ledger still works normally afterwards.
        let next = try ledger.append(TestSupport.makeEvent(index: 9))
        XCTAssertEqual(next.sequence, 2)
    }

    func testDuplicateIDsInsideOneBatchRejectTheWholeBatch() throws {
        let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
        let shared = UUID()

        XCTAssertThrowsError(
            try ledger.append([
                TestSupport.makeEvent(index: 1),
                TestSupport.makeEvent(index: 2, eventID: shared),
                TestSupport.makeEvent(index: 3, eventID: shared),
            ])
        )
        XCTAssertEqual(try ledger.allEvents().count, 0)
    }

    func testInvalidEnvelopeFailsFastWithoutTouchingTheLedger() throws {
        let url = TestSupport.makeTemporaryDatabaseURL()
        let ledger = try EventLedger(databaseURL: url)
        _ = try ledger.append(TestSupport.makeEvent(index: 1))

        let invalidJSON = TestSupport.makeEvent(index: 2, payload: Data("not json".utf8))
        let emptyEventType = TestSupport.makeEvent(index: 3, eventType: "   ")
        let zeroSchemaVersion = TestSupport.makeEvent(index: 4, payloadSchemaVersion: 0)
        let blankProducer = TestSupport.makeEvent(
            index: 5,
            provenance: EventProvenance(producer: "")
        )

        for event in [invalidJSON, emptyEventType, zeroSchemaVersion, blankProducer] {
            XCTAssertThrowsError(
                try ledger.append([TestSupport.makeEvent(index: -1), event])
            ) { error in
                guard error is EventLedger.LedgerError else {
                    return XCTFail("expected LedgerError, got \(error)")
                }
            }
        }

        XCTAssertEqual(try ledger.allEvents().count, 1, "invalid envelopes must leave the ledger untouched")
    }
}
