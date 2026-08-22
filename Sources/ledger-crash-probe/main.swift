import Darwin
import Foundation
import GRDB
import LiraCore

// Test-only helper for CrashRecoveryTests. Never shipped.
//
// Usage:
//   ledger-crash-probe <db-path> single <target-count> <ack-every>
//   ledger-crash-probe <db-path> batch <batch-size> <groups> <ack-every>
//
// Appends synthetic events to a fresh ledger. Payload of event i is
// {"index": i}, so a survivor's payload must match its sequence — torn or
// reordered writes are detectable. After each group of `ack-every` committed
// events it prints "COMMITTED <last-sequence>" and pauses, giving the test
// process a window to observe progress and SIGKILL between commits.
//
// In batch mode it ends with a torn phase: it opens one more transaction,
// inserts <batch-size> rows WITHOUT committing, prints "READY", and sleeps
// holding the transaction open. A test that kills on READY therefore lands
// the SIGKILL inside a live, uncommitted write.

let usage = """
usage: ledger-crash-probe <db-path> single <target-count> <ack-every>
       ledger-crash-probe <db-path> batch <batch-size> <groups> <ack-every>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[ledger-crash-probe] \(message)\n".utf8))
    exit(2)
}

func makeEvent(index: Int64, aggregateID: UUID) -> PendingEvent {
    let payload = try! JSONSerialization.data(
        withJSONObject: ["index": Int(index)],
        options: [.sortedKeys]
    )
    return PendingEvent(
        aggregateKind: .goal,
        aggregateID: aggregateID,
        eventType: "probe.appended",
        payloadSchemaVersion: 1,
        provenance: EventProvenance(producer: "crash-probe"),
        payload: payload
    )
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else { fail(usage) }

let databasePath = arguments[1]
let mode = arguments[2]

do {
    let ledger = try EventLedger(databaseURL: URL(fileURLWithPath: databasePath))
    let aggregateID = UUID()

    switch (mode, arguments.count) {
    case ("single", 5):
        guard let targetCount = Int(arguments[3]), targetCount > 0,
              let ackEvery = Int(arguments[4]), ackEvery > 0 else { fail(usage) }

        for index in 1...Int64(targetCount) {
            _ = try ledger.append(makeEvent(index: index, aggregateID: aggregateID))
            if index % Int64(ackEvery) == 0 || index == Int64(targetCount) {
                print("COMMITTED \(index)")
                fflush(stdout)
                usleep(50_000)
            }
        }

    case ("batch", 6):
        guard let batchSize = Int(arguments[3]), batchSize > 0,
              let groups = Int(arguments[4]), groups > 0,
              let ackEveryGroups = Int(arguments[5]), ackEveryGroups > 0 else { fail(usage) }

        var nextIndex: Int64 = 0
        for group in 1...groups {
            var batch: [PendingEvent] = []
            batch.reserveCapacity(batchSize)
            for _ in 0..<batchSize {
                nextIndex += 1
                batch.append(makeEvent(index: nextIndex, aggregateID: aggregateID))
            }
            let committed = try ledger.append(batch)
            if group % ackEveryGroups == 0 || group == groups {
                print("COMMITTED \(committed.last!.sequence)")
                fflush(stdout)
                usleep(50_000)
            }
        }

        // Torn phase: hold one uncommitted transaction open until killed.
        let pool = try DatabasePool(path: databasePath)
        try pool.write { db in
            for offset in 1...batchSize {
                let event = makeEvent(index: nextIndex + Int64(offset), aggregateID: aggregateID)
                try db.execute(
                    sql: """
                        INSERT INTO domain_event
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
                        String(decoding: try JSONEncoder().encode(event.provenance), as: UTF8.self),
                        event.payload,
                    ]
                )
            }
            print("READY")
            fflush(stdout)
            sleep(120)
        }

    default:
        fail(usage)
    }

    print("DONE")
    fflush(stdout)
} catch {
    fail("\(error)")
}
