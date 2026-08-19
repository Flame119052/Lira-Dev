---
status: accepted
---

# Provider-agnostic model architecture: owner-chosen primary, dispatch to any provider

Extends the local-only resident-model design to a full provider-agnostic architecture: the owner picks a primary provider (local model, opencode Go, or another cloud provider) as Lira's main foreground "brain," and that primary can dispatch specific sub-tasks to any other provider — mirroring how bb (this project's own build orchestrator) lets one primary thread spawn child threads on other providers, and directly extending `ADR-0010`'s coding-agent dispatch mechanism beyond coding tasks.

**Decision:**

1. **`ModelProvider` port** — the owner-selected primary foreground provider. Local (per `ADR-0006`/`ADR-0008`'s zero-or-one-resident-model rule when local is chosen) or a cloud option including opencode Go, via the same identity-preserving contract already decided in `ADR-0007`: "Identity, memory, relationship continuity, policy, and evidence are Lira-owned. A provider does not become Lira's identity."
2. **`WorkerAdapter` port** — dispatched sub-tasks to any other provider, using direct subprocess + structured JSON streams (`ADR-0010`), with an `AcpAdapter` implementation covering opencode Go and other ACP-speaking tools (Agent Client Protocol: a real public spec, Apache-2.0, JSON-RPC over stdio, already referenced in the reference repo's `UPSTREAMS.md` as the intended portable worker transport — this decision formalizes rather than invents that reference).
3. **No dependency on bb at runtime** — Lira implements its own version of this pattern directly, the same choice already made for coding-agent dispatch, not a literal embedding of bb.
4. **Owner-facing simplicity preserved**: switching primary provider, or a dispatched sub-task using a different one, never changes what Lira sounds like or remembers — the five-layer personality (`ADR-0015`) and canonical memory stay provider-independent.

**Why:** almost entirely composes decisions already made (`ADR-0007`, `ADR-0010`) rather than inventing new machinery — the real addition is naming opencode Go specifically as a first-class primary/dispatch option and formalizing ACP as the concrete mechanism for it.
