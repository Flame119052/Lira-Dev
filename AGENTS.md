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

## Status

**Baseline checkpoint (2026-08-22): planning phase complete, implementation starting.** 18 ADRs (`docs/adr/0001`-`0018`) decided via `/wayfinder`, collapsed into one build spec (`#32`) via `/to-spec`, split into 41 dependency-ordered, audited tickets (`#33`-`#73`) via `/to-tickets`. Frontier ticket (no open blockers): `#33` — repo scaffold + durable core event ledger. No application code exists yet as of this checkpoint; everything before this point is planning/decision artifacts (ADRs, research docs, this spec). Tag `planning-baseline` on `main` marks this exact point for future reference.

## Reference

The prior Lira implementation attempt (scrapped for poor structure and unverifiable quality — see `docs/adr/0001`) lives at `/Volumes/iMac II/Lira` on an external drive. Its `VISION.md`, `PRD.md`, `DECISIONS.md`, and `docs/*` are a strong first draft for this rebuild's product and architecture thinking — read them for ideas, never copy code from them directly.
