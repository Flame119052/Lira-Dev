import Darwin
import Foundation
import LiraCore

// Test-only helper for CrashRecoveryTests. Never shipped.
//
// Usage: ledger-crash-probe <db-path> <single|batch> <target-count> <batch-size> <ack-every>
//
// Appends synthetic events to a fresh ledger until target-count is reached.
// Payload of event i is {"index": i}, so a survivor's payload must match its
// sequence — torn or reordered writes are detectable. After each group of
// `ack-every` committed events it prints "COMMITTED <last-sequence>" and
// sleeps briefly, giving the test process a window to observe progress and
// SIGKILL this process between commits (or mid-batch in batch mode).

let usage = "usage: ledger-crash-probe <db-path> <single|batch> <target-count> <batch-size> <ack-every>"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[ledger-crash-probe] \(message)\n".utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 6 else { fail(usage) }

let databasePath = arguments[1]
let mode = arguments[2]
guard mode == "single" || mode == "batch" else { fail(usage) }
guard let targetCount = Int(arguments[3]), targetCount > 0 else { fail(usage) }
guard let batchSize = Int(arguments[4]), batchSize > 0 else { fail(usage) }
guard let ackEvery = Int(arguments[5]), ackEvery > 0 else { fail(usage) }

do {
    let ledger = try EventLedger(databaseURL: URL(fileURLWithPath: databasePath))

    let aggregateID = UUID()
    var nextIndex: Int64 = 0
    var committedSinceAck: Int64 = 0

    while nextIndex < Int64(targetCount) {
        let count = min(Int64(batchSize), Int64(targetCount) - nextIndex)
        var batch: [PendingEvent] = []
        batch.reserveCapacity(Int(count))
        for _ in 0..<count {
            nextIndex += 1
            let payload = try JSONSerialization.data(
                withJSONObject: ["index": Int(nextIndex)],
                options: [.sortedKeys]
            )
            batch.append(
                PendingEvent(
                    aggregateKind: .goal,
                    aggregateID: aggregateID,
                    eventType: "probe.appended",
                    payloadSchemaVersion: 1,
                    provenance: EventProvenance(producer: "crash-probe"),
                    payload: payload
                )
            )
        }

        let committed = try ledger.append(batch)
        committedSinceAck += Int64(committed.count)

        if committedSinceAck >= Int64(ackEvery) || nextIndex == Int64(targetCount) {
            print("COMMITTED \(committed.last!.sequence)")
            fflush(stdout)
            committedSinceAck = 0
            // Pause so the parent can read the line and deliver SIGKILL
            // before the next commit group starts.
            usleep(50_000)
        }
    }

    print("DONE")
    fflush(stdout)
} catch {
    fail("\(error)")
}
