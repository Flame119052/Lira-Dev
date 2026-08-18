---
status: accepted
---

# Adaptive trust calibration: human-ratified, scoped, decaying rule proposals

Further refines `ADR-0004`/`ADR-0012`'s autonomy policy with the "gets smarter with use" mechanism the owner asked for, while preserving the non-negotiable that a model can never approve itself or expand its own authority.

**Decision:** Lira tracks a track record per rule object (per bucket or per learned per-app rule, `ADR-0012`) — approvals, denials, corrections. When a rule clears a real clean-streak threshold, Lira **proposes** loosening it through the same channel as any other thing it wants to surface to the owner — never applies the change itself. Every proposal is:

- **Scoped** — affects exactly one rule, never a general trust increase.
- **Revocable and decaying** — a later denial or correction on that same rule drops its trust back down; a clean streak doesn't stay maxed out permanently from past behavior alone.
- **Logged** — an append-only record of every grant, loosening, and decay event, inspectable by the owner.

Separately, and consistent with completion-evidence principles already established for the build process (`ADR-0001`): any claim that Lira *finished* an action gets verified by something outside Lira's own report (checking the email actually sent, the file actually deleted) — a model's narration of success is never itself the evidence.

**Why:** matches the universal pattern found across every real system surveyed — OS permission grants, OAuth/capability delegation, human-in-the-loop agent tiers, and adjustable-autonomy research all put trust loosening in a human-ratified act via a separate deterministic mechanism, never a model self-grant. This keeps genuine adaptivity ("smarter over time") fully compatible with `ADR-0004`'s hard boundary.
