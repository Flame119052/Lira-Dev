---
status: accepted
---

# Autonomy-policy granularity: category buckets + auto-learned per-app rules

Refines `ADR-0004`'s onboarding autonomy dial, which was originally scoped as flat action categories ("controlling other apps") — too coarse, since the owner correctly flagged that different apps warrant different trust (e.g. Notes vs. a banking app).

**Decision:** two-layer granularity, following the pattern used across every comparable system surveyed (iOS/Android permissions, macOS TCC/entitlements, Little Snitch/LuLu, browser extensions, agent frameworks like Claude Code/LangGraph/AutoGPT/OpenCode/Cline):

1. **Owner-configured category buckets** (e.g. financial apps, communication apps, notes/creative apps, system settings) as the primary, plain-language surface — a handful of groups, not a per-app configuration table.
2. **A remembered, ask-once escape hatch**: the first time Lira wants to act in a specific app not clearly covered by a bucket default, it asks in context and remembers the answer. Fine-grained per-app rules accumulate from these real approvals over time — never hand-authored by the owner from a blank slate.

**Why:** every system surveyed converges on this shape because it's the only one that scales to "the owner uses 100+ apps" without either overwhelming them with configuration or leaving the door open for silent overreach. Dynamic/inferred risk classification (Lira guessing an app's risk level) is useful only as a suggestion for what to ask about — the actual enforced boundary stays the deterministic rule set plus the macOS sandbox, preserving `ADR-0004`'s "a model cannot approve itself" invariant: this is a rules *engine* decision, not a model judgment call.

**Consequence:** feeds directly into the adaptive trust-calibration design (`ADR-0004`'s further refinement, ticket #24) — the unit being tracked for "gets smarter with use" is these bucket/per-app rule objects, not an abstract global trust score.
