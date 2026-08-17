---
status: accepted
---

# Carried-forward decisions from the prior Lira implementation

Full reasoning for all of these lives in the prior repo's `DECISIONS.md` (reference copy at `/Volumes/iMac II/Lira/DECISIONS.md`, external drive — read for detail, never copy code from it). This ADR records which parts of that ledger survive this rebuild's architecture reconsideration, so the next session doesn't have to re-litigate all 39 old ADRs from scratch.

## Inherited as-is (mechanism-level, not reopened)

- Native durable Swift core as the sole writable-database owner; SQLite via GRDB.
- Append-only domain-event ledger backing durable, recoverable agent state (goals/runs/steps/effects survive process death).
- SQLite + FTS5 as canonical memory storage (not a heavy external vector service); a vector index is an optional later addition, not a default.
- Authenticated XPC / owned Unix-socket IPC between components; no open, unauthenticated localhost control plane.
- Playwright + CDP with an isolated default browser profile; ephemeral contexts for sensitive/throwaway work.
- Activepieces as the third-party connector hub (email, calendar, messaging, etc.), behind Lira's own tool-adapter boundary.
- MCP as the tool protocol, ACP as the portable agent protocol, provider-native structured streams (not parsed decorative terminal text) for worker status.
- A single resource governor that reserves measured memory/compute envelopes and pauses/evicts background work under real memory pressure, prioritizing foreground responsiveness.
- Deterministic policy (never model output) as the authority for capability scope, risk tier, and approval eligibility — refined, not replaced, by `0004`'s owner-configured autonomy thresholds.
- Zero-or-one resident custom local generative model, one decode lane, foreground always wins — non-negotiable, unchanged.
- Per-app-scoped, visible screen/computer control (captures and acts within one target app's window, shown via a preview) rather than whole-screen takeover or invisible background automation — reconfirmed 2026-08-17, matches the owner's explicit "Codex Computer Use, let me keep working otherwise" goal.
- Native voice: wake word ("Hey Lira") plus push-to-talk fallback, on-device speech-to-text by default — reconfirmed 2026-08-17.

## Can't be decided before code exists — deferred to the relevant milestone, not skipped

- Exact local model pick and quantization (needs a real bake-off on this specific 16GB machine).
- TCC permission-broker shape (dedicated XPC helper vs. folded into the main app).
- Computer-control stack specifics (Cua vs. public accessibility-API Swift stack).
- WebRTC transport choice for remote/iPhone access (SmallWebRTC/Pipecat vs. Pion).
- Whether to add a vector index alongside FTS5, and which embedding model.
- MLX stream-cancellation mechanics, adaptive-reasoning token budgeting, idle-timeout conversation branching — all real implementation discoveries from the old build, worth reading when that milestone is reached, not decisions to make on paper now.

## Needs rewriting, not re-deciding — first concrete task after this interview closes

- The old Codex-specific mandatory review lifecycle (prior ADR-035/036) is superseded by `0001`'s bb + CI + second-agent-review model, but hasn't actually been rewritten into a working process yet. This is the first piece of process work once the design interview concludes — not a fresh design question, a known follow-up.
