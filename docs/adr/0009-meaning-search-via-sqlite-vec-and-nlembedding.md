---
status: accepted
---

# Meaning search from v1: sqlite-vec + Apple NLEmbedding

Reconsidered after the owner confirmed wanting semantic ("meaning") search in v1, not deferred — reversing the research ticket's FTS5-only-for-v1 recommendation, which was based on the assumption that vector search was optional/future.

**Decision:** add a vector index alongside the already-decided SQLite+FTS5 canonical memory, using `sqlite-vec` (a lightweight in-SQLite extension, not a separate server process) for storage, and Apple's on-device `NLEmbedding` (part of the Natural Language framework — zero download, ships with macOS, the same underlying tech behind Spotlight/Photos/Notes' own on-device semantic search) as the default embedder. `nomic-embed-text-v1.5` (a real downloadable ~0.14GB model, identified in the original research as the fallback) is not used unless `NLEmbedding`'s retrieval quality proves insufficient in practice.

**Why:** this is the combination that satisfies both "add real meaning search" and "heavily optimize and simplify architecturally" simultaneously — no separate vector-database process, no model download, no extra resident memory beyond what's already part of the OS.

**Explicitly deferred, not built now:** multi-tier resource profiles (different builds for different Mac hardware). Reopening that surface now would work against the optimization/simplification goal, not serve it — v1 stays one well-optimized tier, consistent with the prior implementation's own `essential_8gb` deferral (`ADR-0006`).
