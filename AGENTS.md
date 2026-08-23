# Lira agent workflow

Provider-neutral entry point for any coding harness working on Lira (Claude Code, Codex, opencode, others via bb). `CLAUDE.md` exists alongside this file for whatever is genuinely Claude-Code-specific; everything else lives here.

The full binding execution workflow (review lifecycle, quality gates, milestone process) is not written yet — see `docs/adr/0001-bb-orchestrated-build-with-mandatory-independent-verification.md` for the standing trust model (CI green + second-agent review + owner exercises the app) this workflow needs to be built around. Rewriting that into a working process is the first task after project setup, not yet done.

## Agent skills

### Issue tracker

Issues and design tickets live as GitHub issues on this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Standard five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), unchanged from defaults. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Working agreement

- **Owner is not a coder.** Explain any technical/process term in plain language before asking for a decision — never assume familiarity, even with common software terms.
- **Every question to the owner must include a recommended option**, clearly marked, with the reasoning behind it — never present a bare list of choices and leave the owner to adjudicate alone. This applies everywhere, not only inside `/grill-with-docs`/`/wayfinder`-style interviews.
- **Watch for overengineering, actively, not just when the owner flags it.** Before proposing a technical approach, ask whether a simpler one already covers the real requirement (e.g. Tailscale already solving NAT traversal made a full WebRTC stack unnecessary for voice — see `docs/adr/0008`). Prefer the option with less total dependency surface when it genuinely covers the need, and say so explicitly when a fancier option was considered and rejected for this reason.

## Implementation

- **`/implement` always works on a fresh branch, never commits directly to `main`.** Before starting a ticket, create and check out `impl/<issue-number>-<short-slug>` (e.g. `impl/33-repo-scaffold-event-ledger`) off the latest `main`. This overrides `/implement`'s own default of committing to the current branch — that default is fine for a repo where "current branch" is already a feature branch, but here `main` is the trunk everyone builds from, so every ticket needs its own branch to keep `main` clean until review.
- **Once started on a ticket, run to completion without pausing for interim confirmation** — TDD the slice, run tests, run `/code-review`, commit. Only stop early if genuinely blocked (a real missing decision, a failing precondition), not to check in on progress.
- Each ticket branch is independent; do not build one ticket's branch on top of another's uncommitted work — if a ticket is blocked, wait for its blocker to land on `main` (or open a PR) first, per the dependency edges recorded on each ticket (`#33`-`#73`, tracked under map `#4` / spec `#32`).
- **Primary test seam:** most behavior is verified by reading events back from the domain-event ledger (`LiraCore.EventLedger`). See `docs/event-ledger.md` before writing tests that assert on anything else.

## Mandatory multi-model audit (binding for every issue/task)

No ticket's work is "done" when the implementer says it is. Before any PR is merge-ready, the implementing agent **must spawn four independent auditor threads** — different models via different CLIs — and drive their findings to resolution. This is the working form of ADR-0001's second-agent-review trust model, mandated by the owner 2026-08-22 and deepened same day into a full-scope review charter (rationale + primary sources: `docs/research/2026-08-22-audit-rigor-frameworks.md`).

**The four auditor slots** (spawn via `bb thread spawn --project proj_hw9cysya8f`, each with `--new-environment worktree --base-branch <PR branch>` so they verify the exact PR state in isolation):

| Slot | Provider | Model |
| --- | --- | --- |
| Sol | `codex` | `gpt-5.6-sol` (`--reasoning-level medium`) |
| Opus | `claude-code` | `claude-opus-5` |
| DeepSeek V4 Flash | `acp-opencode2` | `opencode-go/deepseek-v4-flash` |
| Muse Spark 1.2 Contributor | `acp-opencode2` | `opencode-go/muse-spark-1.2-contributor` |

### Audit scope — ten mandatory dimensions

Auditors do not merely diff against acceptance criteria. Every auditor must analyze **every dimension A–J** below against the full PR state (code, tests, docs, commit history). The audit comment must contain one section per dimension — a dimension with nothing to flag is stated affirmatively ("covered, no findings"), because silence between findings must mean *analyzed and clean*, never *skipped*. Tag every finding `[<letter>]` so coverage is auditable at a glance.

- **A. Spec fidelity (now).** Every acceptance criterion gets an explicit PASS / FAIL / NOT-APPLICABLE with evidence. No claim is taken on faith from issue, PR body, or implementer — verify it.
- **B. Correctness under adversity (FMEA lens).** Enumerate the failure modes this change introduces or worsens; for each, trace the effect beyond its local site, rank severity × likelihood × detectability-before-impact, and demand either a mitigation or an explicit accepted-risk statement. Detection credited only if it fires before user impact.
- **C. Threat delta (STRIDE lens).** What new tamper / repudiation / disclosure / denial-of-service / elevation-of-privilege surface does this add? For anything touching the event ledger specifically: is append-only tamper-*evident* (not just blocked), can any action be repudiated by its producer, where does flooding or dependency loss flip behavior fail-open?
- **D. Blast radius (ticket DAG).** Using the dependency edges on tickets `#33`–`#73`: name which future tickets consume this contract, what silently breaks in them if its assumptions shift, and the worst credible "largest-unit" failure story this enables.
- **E. Pre-mortem (future implications).** Assume six months have passed and this change failed catastrophically: narrate the single most plausible specific cause (a story, not a category), then list which generated failure stories currently have no mitigation or monitoring. Include second-order effects — what happens *after* the intended benefit lands.
- **F. Implicit contract exposure (Hyrum's law).** Which observable-but-unpromised behaviors will later tickets start depending on unless documented or guarded now? For schema/payload surfaces: evolution must be additive and forward-only (event payloads are immutable — a migration that reinterprets them is a blocker).
- **G. Chesterton's fence.** For everything this PR removes, reverts, rejects, or simplifies away: reconstruct why it existed before agreeing it is safe to drop. Absence of remembered purpose is not evidence of absence of purpose.
- **H. Resource & privacy envelope.** Unbounded growth (ledger rows, caches, logs), memory/CPU/disk trajectory on the fixed 16GB M4 budget, startup/runtime degradation, and any change to data locality versus the local-first posture (`ADR-0006`: nothing leaves the machine uninvited).
- **I. Operability.** When this misbehaves in production, how would someone diagnose it — ideally through the primary test seam (reading ledger events)? Name what is observable, what is blind, and what degrades how when each dependency dies.
- **J. Proportionality (working agreement).** Overengineering check in *both* directions: complexity without a demonstrated requirement (cut it), and over-minimalism that fails B–E above (say so rather than applauding leanness).

### Materiality bar — rigor without nitpicking

An empty findings list on solid work is a **successful audit**, not a failed one. Findings exist to protect the owner, not to prove reviewer effort — a gate flooded with manufactured issues is as broken as a gate that misses real ones. Every finding must clear this bar; anything below it dilutes the signal the merge gate depends on.

A finding qualifies only if it names a concrete mechanism — trigger, consequence chain, and a plausible path to impact within the ticket-DAG horizon. Concretely, one of:

- a **reproduced defect** (command + observed vs expected output), or
- a **violated acceptance criterion or standing invariant**, quoted, or
- a **specific failure story** (dimension B/E) whose triggering condition is reachable through behavior the change actually exhibits or invites, or
- an **unbounded resource or privacy exposure** with its growth mechanism named.

The following never qualify as findings: style/formatting preferences absent a documented standard; "could be more abstract/tested/configurable" without a demonstrated requirement (dimension J cuts both ways); failure modes requiring an actor or usage pattern nothing in the system exhibits or invites; demands for features no criterion asks for; severity inflation to appear thorough. Speculative items may be recorded only as `note`, explicitly marked speculative. Calibration duty: severity definitions are ceilings — if you cannot write the consequence chain, it is not a major. One reproduced blocker outweighs ten argued maybes; auditors are graded on signal, not volume. The implementer may reject any finding as below the bar with stated reasoning, and such rejections stand unless the owner overrides them.

### Independence and evidence rules

- Auditors are research-and-verify only: no pushes, no merges, no tracked-file edits.
- Each auditor works from its own worktree off the exact PR branch and **runs the test suite itself** — CI green is never accepted on faith.
- An audit is posted before reading any other audit on the PR; the implementer may not audit their own work.
- Every finding cites `file:line` plus either a reproducing command/output or the quoted acceptance criterion, invariant, or claim it violates. Reproduced defects outrank argued ones.

### Output and merge gate

Each auditor posts exactly one consolidated comment on the PR starting `**[Independent audit — <identity>]**`, containing the ten dimension sections, findings numbered `[<letter>][severity]`, and ending with exactly `Verdict: APPROVE` or `Verdict: REQUEST CHANGES`; then reports verdict + top findings back to the parent thread.

Severity: **blocker** = violates an acceptance criterion or standing invariant; **major** = real defect or risk likely to bite within the ticket-DAG horizon; **minor / note** = worth recording, non-gating.

A PR is merge-ready only when (a) CI is green on the final head SHA, (b) all four verdicts exist, and (c) no blocker or major finding remains unresolved. The implementer must respond to every finding on the PR — fixed with a commit referencing it, or rejected with explicit reasoning. The owner may waive specific findings explicitly; silence is not a waiver. If an auditor thread dies to a transient provider error, respawn that same slot until a real verdict exists — never skip or substitute slots silently.

## Naming conventions

**One work item, one identifier: its GitHub issue number.** Positional
prefixes once used in ticket titles (`01 —`) were display-ordering hints,
not identities — they never appear in branches, commit subjects, or PR
titles. Ordering lives in blocker edges between issues and each ticket
body's traceability footer.

- **Branches:** `<kind>/<issue-number>-<kebab-slug>` — slug of 3–5 lowercase
  words drawn from the issue title. Kinds: `impl/` (ticket implementation),
  `fix/` (defect fix tied to an issue), `process/` (repo process/docs work,
  no issue number required), `research/`, `prototype/`. Ephemeral bb-audit
  worktree branches (`bb/…`) are exempt.
- **Commit subjects:** imperative mood, ≤72 chars; commits advancing a
  ticket end with the issue reference, e.g. `… (#33)`. Repo-level
  process/doc commits on `main` need no number.
- **Pull requests:** one PR per issue. Title is
  `<issue-number> — <issue title, verbatim>`, plus ` — <scope>` when the PR
  covers only part of the issue or is a remediation pass (e.g.
  `33 — Repo scaffold + durable core event ledger — R2 audit remediations`).
  The body states `Closes #N`.
- **Audit comments and auditor thread titles** follow the formats fixed in
  the Mandatory multi-model audit section above.
- **Everything else** (tags, labels, file names): lowercase kebab-case.

## Status

**Baseline checkpoint (2026-08-22): planning phase complete, implementation starting.** 18 ADRs (`docs/adr/0001`-`0018`) decided via `/wayfinder`, collapsed into one build spec (`#32`) via `/to-spec`, split into 41 dependency-ordered, audited tickets (`#33`-`#73`) via `/to-tickets`. Frontier ticket (no open blockers): `#33` — repo scaffold + durable core event ledger. No application code exists yet as of this checkpoint; everything before this point is planning/decision artifacts (ADRs, research docs, this spec). Tag `planning-baseline` on `main` marks this exact point for future reference.

## Reference

The prior Lira implementation attempt (scrapped for poor structure and unverifiable quality — see `docs/adr/0001`) lives at `/Volumes/iMac II/Lira` on an external drive. Its `VISION.md`, `PRD.md`, `DECISIONS.md`, and `docs/*` are a strong first draft for this rebuild's product and architecture thinking — read them for ideas, never copy code from them directly.
