---
status: accepted
---

# Personality: five-layer bounded-growth architecture, formally adopted

Formally re-adopts and strengthens the prior implementation's five-layer personality design (originally `ADR-018` in the reference repo), which was under-carried-forward when this rebuild's `ADR-0006` first catalogued inherited decisions. Confirmed against real-world precedent (Character.AI, Replika, Pi, ChatGPT's memory/custom-instructions, Anthropic's own published persona guidance) and academic work on persona consistency and memory architecture (`docs/research/personality-layers.md`).

**Decision:** personality is assembled fresh every turn by a deterministic assembler from five layers, not one static prompt:

1. **Immutable constitution** — the hard floor (no manipulation tactics, always honest about being an AI, never claims real sentience). Never changes, not even by owner request, per `ADR-0005`.
2. **User-owned controls** — explicit style settings the owner sets directly (verbosity, formality, humor).
3. **Evidence-backed learned preferences** — patterns Lira proposes based on real interaction history; owner confirms before adoption, same governed-proposal pattern as the autonomy-trust design (`ADR-0013`) — never silently adopted.
4. **Relationship continuity** — the ongoing shared history that makes it feel like one continuous relationship, not a fresh start each conversation.
5. **Ephemeral context** — short-lived signals that expire on their own rather than becoming permanent traits.

**Three additions beyond the original design, adopted per research recommendation:**

- **Explicit relationship-role boundary** — a stated definition of what this relationship is (a capable presence/companion) and is not (not a romantic partner, not a therapist, not a replacement for human relationships), preventing unstated drift.
- **Anti-dependency as a first-class, testable conformance check** — not vague guidance but something actually checked (same discipline as `ADR-0001`'s CI/review trust model), given real precedent shows unhealthy attachment can form in as little as 3 weeks (Replika, Character.AI incidents).
- **No lossy summary memory** — old memories are never compressed into vague blobs over repeated summarization (which loses nuance and can drift); the actual source stays traceable, consistent with the provenance principle already governing the rest of Lira's memory.

**Why:** a single static personality prompt cannot safely or consistently grow — layering makes behavior portable, correctable, testable, and resistant to manipulation or drift, and the specific additions close real gaps the original design didn't address.
