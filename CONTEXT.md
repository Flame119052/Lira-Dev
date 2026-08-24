# Lira

Lira is a JARVIS-style, local-first macOS agent: a durable, capable, personal presence — not a chat wrapper — being rebuilt from a clean codebase after the prior implementation attempt was scrapped for poor structure and unverifiable quality. See `docs/adr/` for the decisions behind this rebuild's process and architecture.

## Language

**Owner**:
The one person Lira serves — who directs it, approves high-risk actions, and whose Mac hosts this instance. Distinct from any future general term for a person using a *different* installation of Lira, which hasn't been named yet because multi-install support isn't a live design constraint for v1.
_Avoid_: User, Client, Account holder

**Goal**:
A durable outcome the owner asked Lira to pursue. Recorded as ledger events on a `goal` aggregate. Has zero or more runs. State is projected from those events (and from child runs) — never from a parallel table.
_Avoid_: Task, Job, Ticket (for this concept)

**Run**:
One attempt at a goal. Recorded as ledger events on a `run` aggregate. Has zero or more steps. The unit that timeout, cancel, and crash-reconciliation must not leave as a zombie.
_Avoid_: Session, Execution (for this concept)

**Step**:
One unit of work inside a run (a model turn, a tool call). Recorded as ledger events on a `step` aggregate. The model→tool→result turn loop is a sequence of events on this aggregate, not a separate store.
_Avoid_: Action, Attempt (for this concept; #42's effect executor owns real-world effects)
