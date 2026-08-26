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
| `aggregateKind`        | Which aggregate shape: `goal`, `run`, `step`, or `effect`. Enforced by a DB CHECK too — rows are immutable, so one garbage value would poison reads forever. |
| `aggregateID`          | Identity of the aggregate this event belongs to.                        |
| `eventType`            | Discriminator of what happened within the aggregate (`"goal.created"`). |
| `payloadSchemaVersion` | Version of the payload schema; payloads are opaque JSON to the ledger.  |
| `occurredAt`           | Wall-clock timestamp. Informational only — never used for ordering.     |
| `provenance`           | What produced this event: producer kind plus model/provider/revision where applicable. |

## Guarantees (all structural, none by convention)

- **Append-only is enforced by the database.** `UPDATE`/`DELETE` on event
  rows are rejected by triggers inside the schema itself, on any connection.
  A `BEFORE INSERT` guard additionally aborts any insert whose `event_id`
  (case-insensitively) or `sequence` already exists — this closes SQLite's
  default-off hole where `INSERT OR REPLACE` performs an implicit DELETE
  without firing the delete trigger (auditors demonstrated that rewrite
  path). Lira's own connections also set `PRAGMA recursive_triggers = ON`.
  The triggers ship in migration v1 so every database has them from birth.

  **Tamper-evidence decision (recorded, deferred):** these mechanisms
  *block* writes through SQL but do not make the file tamper-*evident* — an
  actor who can drop triggers and rewrite rows could also hide the edit by
  restoring them. That is outside v1's threat model (single-owner machine,
  local-first, no network surface); if cryptographic tamper-evidence is ever
  wanted (e.g. hash-chained sequences), it is a deliberate decision for the
  audit-log work, not something to inherit silently.
- **Atomic appends.** One event or a batch commits entirely or not at all;
  readers never see partial batches (WAL snapshot isolation).
- **Bounded rows.** Payloads are capped at `EventLedger.maxPayloadBytes`
  (1 MiB) and validated as JSON at append; per-row growth is structurally
  bounded. Whole-ledger reads (`allEvents()`, `verifyIntegrity()`) load
  history into memory — fine at personal-machine scale for the foreseeable
  future; revisit with streaming/pagination only when real usage approaches
  it.
- **Forward-only migrations.** Migrations are versioned and never mutate or
  reinterpret existing event payloads; a database migrated by newer code is
  refused at open (`databaseWrittenByNewerVersion`) rather than misread.
  Extending `AggregateKind` is such a migration: SQLite cannot alter a CHECK
  constraint, so the table must be rebuilt in a new migration while
  preserving every trigger, index, and row byte-for-byte.
- **Crash safety.** Committed events survive process death; partially
  written transactions are discarded by SQLite recovery. `verifyIntegrity()`
  decodes every row through the exact same path as reads and reports either
  full consistency up to the last committed event or precisely which
  sequences are unreadable plus the last valid point readers can trust.
- **Sequences are contiguous from 1** (not merely monotonic): AUTOINCREMENT
  plus rolled-back-write semantics mean no gaps are consumed, and
  `verifyIntegrity()` treats any gap as an issue. Multiple `EventLedger`
  instances may safely share one database file (WAL serializes writers);
  there is no single-instance requirement.

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

## IPC auth failures

The authenticated IPC plane (`Sources/LiraCore/IPC/`) records a refused
peer as an `effect` event — no new aggregate kind, so no schema migration.

| Field | Value |
| ----- | ----- |
| `eventType` | `ipc.auth_failed` (`IPCEventType.authFailed`) |
| `aggregateKind` | `effect` |
| `aggregateID` | Stable UUID derived from the channel name (`IPCChannel.aggregateID`) |
| `provenance.producer` | `"lira.ipc"` |
| payload v1 | `{channel, reason, observedComponent, expectedComponent, peerPID}` — no secrets |

Reasons are `IPCError.RejectionReason` raw values (`pidNotAllowed`,
`componentMismatch`, `codesignInvalid`, `parentPIDMismatch`,
`handshakeRejected`, `handshakeTimedOut`, …). `observedComponent` is truncated to 128 UTF-8
bytes (`IPCProtocol.maxComponentNameUTF8Count`) so a rejected peer cannot
inflate the row past the ledger payload cap. If even the truncated record
cannot be appended, a second attempt is made with `observedComponent`
omitted; a still-failing append writes one line to stderr rather than
dropping silently.

The handshake `component` string is a claim, not evidence. Production
auth (`DarwinPeerAuthenticator`) requires the claim to equal the
channel's expected component **after** OS credential checks. Parent-pid
alone is not a verification rule (siblings share a parent). Child
processes that share the app's ad-hoc signature (#75) set
`codeSigningRequirement` to nil and **must** bind `allowedPeerPIDs` to
the spawned child pid. Codesign guest lookup uses the peer's audit
token when `LOCAL_PEERTOKEN` supplied one, so a recycled pid cannot
satisfy `SecCodeCopyGuestWithAttributes`.

`IPCChannel.expectedServer` is an optional client-side check of the
listening process's OS credential (pid allowlist / codesign). It
rejects a *different process* that binds a vacant path. A same-user,
same-binary listener that copies the protocol cannot be distinguished
on AF_UNIX; #47's XPC audit-token identity is the stronger plane for
that case. `IPCClient.send` holds an I/O lock for the whole
request/response, so concurrent callers cannot interleave frames.

Pre-auth connections are capped at 16; further accepts are closed with
no handler thread and no ledger row (overflow must not amplify the
ledger). Sequential rejected handshakes release their slot, so the
concurrent cap does not bound ledger growth: a channel records at most
16 `ipc.auth_failed` rows per 60-second window; further rejections in
that window are dropped. A handshake that times out *does* record
`handshakeTimedOut` (subject to that cap). Authenticated sockets do not
carry a receive timeout (handshake only). `IPCClient.close` shuts the
socket down before waiting for an in-flight `send`, so a hung peer
cannot pin reconnect. An oversized `send` (`frameTooLarge`) returns
immediately without draining the socket. `IPCError.invalidated` means
the server sent an invalidate frame; `.timedOut` is handshake-only;
`.disconnected` is a drop. #36 must not treat those three as one signal.
The live `EventLogStore` that attempted `connect` is the one that publishes
handshake `.timedOut`; the app session must keep that store. Catching the
throw on a discarded instance and forcing a placeholder to `.disconnected`
would label a not-yet-ready core (#62) as a drop.

`UnixSocket.preparePath` unlinks only a stale socket inode; a regular
file or directory at the configured path fails closed (`alreadyInUse`).

## App shell IPC (`listEvents`) and on-disk locations

The SwiftUI app (#36) never opens this database. `CoreHost` owns the
ledger and serves `IPCClient.send` with a JSON `listEvents` op
(`Sources/LiraCore/AppSupport/LedgerIPC.swift`). Wire summaries carry
sequence, ids, kind, event type, time, and producer — not payloads
(a 1 MiB payload cannot fit in a 1 MiB IPC frame with envelope fields).
Unknown ops and ledger read failures return `{ok:false,error:…}`; they
do not throw through the socket handler.

If `EventLedger` construction fails (corrupt file, inaccessible path,
`databaseWrittenByNewerVersion`), `CoreHost.start` throws
`CoreHostError.ledgerUnavailable` **before** IPC listens. The app
process stays up and the log shows the ledger-unavailable error; it
does not treat that as an empty log. Production does **not** append
`app.launched` until the window appears, so a first launch with an
empty ledger can paint the empty state; the launch effect then arrives
over the live poll.

`listEvents` pages with a SQL `LIMIT` (`EventLedger.events(afterSequence:limit:)`).
Prefixing in memory after `fetchAll` is forbidden: it would decode the
whole remaining ledger on every page.

`app.launched` is an `effect` (`AppEventType.launched`, producer
`lira.app`, payload `{}`) recorded by `CoreHost` when asked. It is
additive telemetry for the first visible demo, not a lifecycle event.

Paths go through `FileManager.urls(for: .applicationSupportDirectory,
in: .userDomainMask)` (`LiraPaths`). Do not hard-code
`~/Library/Application Support/Lira`. When #73 enables App Sandbox,
that API returns the container directory automatically. An unsandboxed
#36 ledger left outside the container is #73's migration, not a silent
reinterpretation. Socket paths that would exceed Darwin's 104-byte
`sockaddr_un` cap fall back to `/tmp/lira-<uid>/core.sock` so #73's
container prefix cannot break IPC. #62's login-item relaunch must use
the same `LiraPaths` API so it sees one ledger per sandbox state.

XPC helpers (#47) authenticate with `PeerCredential.auditToken` against
the same `PeerAuthenticator`; they do not reimplement versioning,
invalidation, or this ledger event.

## Goal / run / step lifecycle

`RunLifecycle` is the **only** writer of `goal`, `run`, and `step`
events. There is no snapshot table and no in-memory cache that outlives
a command: every call projects from the ledger, validates a transition,
and appends. `init` does not reconcile — the process must call
`reconcile()` on launch.

Producer: `"lira.runtime"`. Payload schema version: `1`. Event type
strings and v1 payload keys are **additive-only** after merge; renaming
is a blocker for #36, #37, #41, and #42.

### States

`pending` → `running` → `awaitingApproval` → `succeeded` | `failed` | `cancelled`

Timeout is `failed` with reason `timedOut`, not a seventh state.
Terminal states are absorbing.

Allowed transitions:

| from | to |
| --- | --- |
| pending | running, cancelled, failed |
| running | awaitingApproval, succeeded, failed, cancelled |
| awaitingApproval | running (approve), failed (deny), cancelled |
| succeeded / failed / cancelled | (none) |

Succeed does **not** cascade up or down: a parent with live children
rejects `succeed` (`hasNonTerminalChildren`). Cancel, fail, and timeout
cascade down to every non-terminal descendant and **up** only when the
parent would otherwise have zero non-terminal children (no zombie runs).
A sibling that is still live blocks the upward cascade.

Parent `awaitingApproval` / `running` for a goal is **derived** from
children. There is no `goal.started` or `goal.awaiting_approval` event.
#36 must not render a parent awaiting event as a distinct owner action.

### Event types (frozen v1)

| eventType | aggregate | payload keys |
| --- | --- | --- |
| `goal.created` | goal | `title`, `deadlineAt?`, `idempotencyKey?` |
| `goal.succeeded` / `failed` / `cancelled` | goal | `reason?`, `idempotencyKey?` |
| `run.created` | run | `goalID`, `deadlineAt?`, `idempotencyKey?` |
| `run.started` / `succeeded` / `failed` / `cancelled` | run | `reason?`, `idempotencyKey?` |
| `step.created` | step | `runID`, `kind`, `deadlineAt?`, `idempotencyKey?` |
| `step.started` | step | `idempotencyKey?` |
| `step.model_called` | step | `idempotencyKey?` (model lives on provenance) |
| `step.tool_called` | step | `tool`, `requiresApproval`, `idempotencyKey?` |
| `step.tool_result` | step | `tool`, `outcome`, `idempotencyKey?` |
| `step.awaiting_approval` | step | `tool?`, `idempotencyKey?` |
| `step.approved` | step | `idempotencyKey?` |
| `step.succeeded` / `failed` / `cancelled` | step | `reason?`, `idempotencyKey?` |

`kind` on a step is a free-form string (e.g. `"model_turn"`). Reasons
used by this module: `timedOut`, `interrupted`, `denied`. String fields
are length-capped (`LifecycleLimits`) so a caller cannot inflate a row
to the ledger's 1 MiB payload cap.

`recordToolCall` requires a preceding `step.model_called` on that step
(`missingModelCall`). `recordToolResult` requires an unmatched
`step.tool_called` for the same `tool` (count of calls minus results
for that name). A result with no recorded call is rejected
(`unmatchedToolResult`). That is the model→tool→result ledger order
#37/#41/#42 may rely on.

Commands from every `RunLifecycle` on a given database file serialize
in-process via a path-keyed lock table and across processes via
`<canonical-ledger>.lifecycle.lock` (`flock`). Both keys use the
symlink-resolved path, so an alias URL to the same inode cannot bypass
the lock (Sol R2). macOS `flock` is process-wide, so the in-process
table is what stops two objects in one process from both passing
`LOCK_EX`. Terminal states stay absorbing even if two objects share
the file.

### Reconciliation

On launch, `reconcile()` (one atomic append):

1. Every aggregate whose **effective** state is `running` (a started
   run or a started step, not a goal) is failed with reason
   `interrupted`, cascading as above. In-flight model/tool work is **not**
   retried — retry is not proven safe until #42 owns effect idempotency.
2. `pending` and `awaitingApproval` are resumed in place (no extra
   event). Subsequent `start` / `approve` still work.
3. Crossed deadlines are failed with `timedOut`.
4. A second `reconcile()` is a no-op: targets are already terminal
   (terminal-check, not an `idempotencyKey`). Because the pass is one
   `EventLedger.append` batch, a crash mid-reconcile discards the whole
   batch and the next launch retries.

### Timeout liveness

Deadlines are enforced on **commands** and on **`reconcile()`**. There
is no background timer thread. A process that sits idle with no
commands will not notice a crossed deadline until the next command or
the next launch. That is an accepted v1 limit, not a silent loss: the
run stays in the ledger and is closed on the next touch. If that next
command is itself illegal after the timeout (for example `recordToolCall`
on a step that just expired), the timeout events still commit — the
throwing command cannot discard them.

### Idempotency

Optional `idempotencyKey` on a command is stored in that event's
payload. Replaying the same `(aggregateID, eventType, key)` returns
the original outcome and appends nothing. Creates are keyed with their
parent too: `goal.created` by `(eventType, key)`, `run.created` by
`(eventType, key, goalID)`, `step.created` by `(eventType, key, runID)`.
The same key on a *different* parent is a new child, not a hijack of
the first. Duplicate `eventID` at the ledger layer remains a caller bug.

