# The domain-event ledger (durable core)

The ledger is the sole source of truth for Lira's state: every goal, run,
step, and effect is recorded as an immutable event in a GRDB/SQLite database
that `LiraCore`'s `EventLedger` exclusively owns and writes
(ADR-0006, ADR-0013). Nothing else maintains parallel authoritative state.

Code lives in:

- `Sources/LiraCore/EventLedger/DomainEvent.swift` — the envelope types
- `Sources/LiraCore/EventLedger/LedgerSchema.swift` — versioned migrations
- `Sources/LiraCore/EventLedger/EventLedger.swift` — append/read/integrity API

## Event envelope

| Field                  | Meaning                                                                 |
| ---------------------- | ----------------------------------------------------------------------- |
| `eventID`              | Stable unique identity, assigned by the caller. Duplicates rejected.    |
| `sequence`             | Monotonic integer, assigned at commit. **Defines total order.**         |
| `aggregateKind`        | Which aggregate shape: `goal`, `run`, `step`, or `effect`.              |
| `aggregateID`          | Identity of the aggregate this event belongs to.                        |
| `eventType`            | Discriminator of what happened within the aggregate (`"goal.created"`). |
| `payloadSchemaVersion` | Version of the payload schema; payloads are opaque JSON to the ledger.  |
| `occurredAt`           | Wall-clock timestamp. Informational only — never used for ordering.     |
| `provenance`           | What produced this event: producer kind plus model/provider/revision where applicable. |

## Guarantees (all structural, none by convention)

- **Append-only is enforced by the database.** `UPDATE`/`DELETE` on event
  rows are rejected by triggers inside the schema itself, on any connection.
  The triggers ship in migration v1 so every database has them from birth.
- **Atomic appends.** One event or a batch commits entirely or not at all;
  readers never see partial batches (WAL snapshot isolation).
- **Forward-only migrations.** Migrations are versioned and never mutate or
  reinterpret existing event payloads; downgraded code refuses a newer file
  rather than misreading it.
- **Crash safety.** Committed events survive process death; partially
  written transactions are discarded by SQLite recovery. `verifyIntegrity()`
  reports either full consistency up to the last committed event or exactly
  what is wrong.

## Primary test seam

**Most Lira behavior is verified by reading events back from this ledger.**
A test drives a subsystem end-to-end, then asserts on what got *recorded* —
not on internal calls or fakes. This works because every subsystem must
route through the ledger to make anything true.

Pattern for future tests:

```swift
let ledger = try EventLedger(databaseURL: TestSupport.makeTemporaryDatabaseURL())
// ...drive the subsystem under test against `ledger`...
let events = try ledger.events(forAggregateID: goalID)
XCTAssertEqual(events.last?.eventType, "goal.completed")
```

Structural guarantees have dedicated tests that bypass the public API with
raw SQLite connections where the point is that enforcement does not depend
on our code: `AppendOnlyTests` (DB-level rejection),
`MigrationCompatibilityTests` (payload immutability across migrations), and
`CrashRecoveryTests` (SIGKILL mid-write via the `ledger-crash-probe` helper
process, then reopen-and-verify).
