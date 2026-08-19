---
status: accepted
---

# Onboarding: conversational first-run, minimal upfront config, real personalization

Resolves the onboarding-flow prototype (ticket #18) once its two blockers — autonomy-policy granularity (`ADR-0012`) and personality architecture (`ADR-0015`) — were settled. Synthesizes elements from all three original prototype variants rather than picking one outright.

**Decision:** onboarding plays out as a real first conversation with Lira (the "conversational" prototype variant's *delivery*), not a settings-form wizard, covering:

1. **The trust-level dial** (Cautious/Balanced/Confident) as the fast default, per `ADR-0004`/`ADR-0012`.
2. **Explicit confirmation on only the highest-stakes action categories** — spending money, deleting things — the ones where a wrong default carries real consequence. Everything else takes the dial's default and gets refined later through real "ask once, remember" moments, per `ADR-0012`. This is the deliberate middle ground between a bare dial (too little control) and a full per-category configuration screen (too much upfront friction) — real precedent showed neither extreme is what shipped systems actually do.
3. **Real personalization choices** — naming Lira, how it addresses the owner, and similar — captured as part of this same first conversation, feeding directly into Layer 2 (user-owned controls) of the personality architecture (`ADR-0015`), not a separate settings pass.

**Why:** the owner explicitly wants onboarding to feel like meeting Lira, not configuring software — while the underlying decisions (dial, two high-stakes confirmations, personalization) stay the same regardless of delivery, the conversational framing is itself a real, deliberate choice given the product's whole premise is presence over utility-app conventions.
