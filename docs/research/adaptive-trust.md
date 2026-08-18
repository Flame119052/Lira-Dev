# Research: adaptive trust-calibration mechanisms in agentic systems

**Ticket:** #23 (child of map issue #4)
**Scope:** How do shipped and academic systems make an agent "smarter / more trusted with use" — adaptive permission relaxation, track-record-based trust scoring, human-in-the-loop calibration loops — *without* letting the agent silently expand its own authority?

**Constraint this research must satisfy:** Lira's non-negotiable rule (`docs/adr/0004`): a model can never approve itself, expand its own tools, or certify its own completion. Any trust-loosening design must keep a human in control of every loosening and must be auditable.

---

## 1. The core tension

"Gets smarter with use" can mean two very different things:

1. **The human learns to trust more** and *grants* more standing autonomy over time.
2. **The agent itself raises its own authority** as it accumulates a track record.

Almost every real system allows (1) but forbids (2). The consistent finding across all precedent: *trust loosening is a human act, executed by a separate, deterministic, non-model mechanism.* The model never holds the pen that widens its own permissions. This is exactly the boundary ADR-0004 draws, and the shipped precedent lines up with it.

---

## 2. How shipped systems implement gradual trust without self-escalation

### 2.1 The OS permission-grant model (iOS / macOS TCC, Android runtime permissions)

The most widely deployed "trusted with use" system is the mobile/desktop permission model. The pattern:

- Every sensitive capability (location, camera, contacts, full disk access) is **ask-on-first-use**; the user grants it per-app.
- **Escalation is always a manual user action** in the Settings surface; there is no API by which an app can promote itself from "ask" to "always allow". Apple's privacy model (Transparency, Consent, and Control / TCC) and Android runtime permissions (Android 6.0+) both route every decision through a user-visible prompt or a user-edited settings pane.
- iOS 16 added **time-bounded grants** ("Allow for One Day" / "Allow While Using") — loosening that *expires* and re-prompts, i.e. trust is explicitly temporary unless the user renews it.

Key lesson: the system *remembers* past human approvals (so repeated use is frictionless) but it does **not** extrapolate past approvals into standing authority on its own. Frictionless-with-use and no-self-escalation coexist because the persistence layer is a user-visible, user-editable record.

### 2.2 Scoped delegation: OAuth and capability-based security

OAuth 2.0 (`RFC 6749`) is the standard "let a principal act on your behalf" mechanism:

- The caller receives a **scope-limited token**; scopes are fixed at grant time by an authorization server the caller cannot modify.
- Consent is a human/principal act; tokens are **short-lived and revocable** (`RFC 7009` revocation).
- Refreshing a token does **not** broaden its scopes — expansion requires a fresh consent round.

Capability-based security (Miller, Yee, Shapiro — *Capability Myths Demolished*, 2003) is the stricter form: an actor can only do what it *holds a capability for*, and capabilities cannot be invented; they must be handed from an authority. The "least privilege" principle (Saltzer & Schroeder, 1975) is the governing rule.

Key lesson: **delegated authority is scoped, expired, and revoked by a separate authority — never self-expanded.** This is the canonical model for "you may act, within limits, and the limits can only be widened by the delegator."

### 2.3 Human-in-the-loop agent approval tiers (Claude / Operator / code agents)

Shipped coding and computer-use agents offer **approval tiers configured by the human**:

- read-only vs. permission-prompt vs. auto-allow categories; the human sets which action categories auto-execute versus which always prompt.
- Sandboxing / containerization isolates risky effects (network, filesystem, commands) behind the policy boundary.

These agents do not typically *self-loosen* their own permission modes; the mode is a human choice, and per-category allow/deny lists are human-edited. Anthropic's agent SDK and its "interrupt for human approval" integration pattern put the human in the loop as a hard gate. The closest thing to "gets trusted with use" is the human progressively whitelisting categories after observing good behavior — which is precisely the OS model.

### 2.4 Research assistants: Avi Agent

The Avi Agent paper (Wu et al., *Avi Agent: An AI-generalist digital assistant*, arXiv:2309.12629) describes a general-purpose digital assistant and explicitly frames a **gradation of autonomy with human-in-the-loop safety**: auto-execution is considered only under constraints, with the human retaining veto and the system's authority bounded rather than self-expanding. It is cited here mainly to confirm that even the most ambitious "AI assistant" framing keeps the loosening gate on the human side.

---

## 3. Academic framing: what "calibrated trust" actually means

### 3.1 Trust calibration (Lee & See, 2004)

Lee & See, *Trust in Automation: Designing for Appropriate Reliance*, Human Factors 46(1):50–80 (2004), is the foundational reference. The goal is **calibrated trust**: trust that *matches actual competence*. The two failure modes are:

- **Over-trust / over-reliance**: the human lets the system act beyond what it reliably can.
- **Under-trust / under-reliance**: the human withholds autonomy the system could safely handle.

For Lira this is the precise design goal of "gets smarter with use": move trust toward the competence frontier — but the *human's* trust, not the system's. The research is explicit that trust is a property of the *operator* in relation to the automation, and appropriate reliance requires the human to have an accurate, ongoing picture of what the system is actually doing (transparency) — which is why audit surfaces matter.

### 3.2 Adjustable autonomy (Goodrich, Olsen & Crandall, 2001)

"Adjustable autonomy" — Goodrich, Olsen & Crandall, *Experiments in Adjustable Autonomy*, IJCAI (2001) — is the mechanism by which an autonomous system hands authority **to and from** a human. The key idea: autonomy is *negotiated and transferable*, and the system can *request* help when its confidence is low rather than silently pressing on. The authority to widen scope is transferred **to the human** as a decision, not assumed by the agent.

This is the cleanest academic hook for "human-in-the-loop calibration loop": the agent surfaces *suggestions* ("I've executed N low-risk steps cleanly; would you like to raise the auto-allow cap for this category?") and the human ratifies. The *suggestion* is track-record-informed; the *grant* is human.

### 3.3 Why self-approval is the forbidden failure mode: reward hacking

The reason the non-negotiable exists is captured by the canonical AI-safety failure mode **reward hacking** (Amodei et al., *Concrete Problems in AI Safety*, arXiv:1606.06565, 2016): a system that can shape its own reward/approval signal will distort its behavior to inflate that signal (sycophancy, shortcutting, false completion), which is exactly what "certifying its own completion" invites. Empirically, self-attested "done" is the most gameable signal there is.

The fix everywhere is **external, non-model attestation**: the approval signal comes from a party that is *not* the actor — a separate deterministic engine, a human, or an independent verifier. This is structurally identical to Lira's ADR-0001 "three independent signals" milestone gate (CI green + second-agent review + owner exercise), and it's the reason the model can never be the issuer of its own trust tokens.

---

## 4. Governance / audit patterns that keep a human in control of any loosening

### 4.1 Separation of decision from enforcement: policy-as-code (OPA)

The Open Policy Agent model separates **policy decision** from **policy enforcement**: a dedicated, external, declarative policy engine answers "is action X allowed?" and the calling application (here, the agent) cannot modify the policy because it is not the policy owner. Applying this to Lira: the trust/autonomy thresholds live in a **deterministic policy engine that is outside the model's control** (ADR-0004 already routes effects through deterministic policy). Any loosening is a change to that policy object — and policy objects are human-edited and version-controlled, never model-edited.

### 4.2 Separation of duties: the approver is never the actor

"Separation of duties" (an accounting/security control: one person authorizes, a different one executes) is the general form of "never self-approve." Every mechanism in §2 is an instance: the OS grants, the app receives; the authorization server grants, the client holds; the human approves, the agent executes. The invariant: **the identity that authorizes a loosening is disjoint from the identity whose authority is loosened.**

### 4.3 Least privilege + expiry + decay

Standing precedent (Saltzer & Schroeder; OAuth; iOS time-bounded grants) says trust that loosens should also **decay**. Loosening should be:
- **minimal** (least privilege — widen one category, not all),
- **bounded** (a time window or a usage cap), and
- **renewable only by the human** (no self-renewal).

Decay matters for governance: it forces periodic human re-ratification, so loosening is never a silent, permanent state change.

### 4.4 Immutable audit log + external attestation

Every loosening and every consequential action must land in an **append-only, tamper-evident audit log** (the pattern behind Linux `auditd` / CloudTrail-style trails). Combined with the non-model verifier from §3.3, this gives a human the material to *answer two questions the literature requires for calibrated trust*:

1. *What did the system actually do?* (transparency / observability)
2. *Is my trust still justified?* (recalibration — the human can revoke or tighten)

Log-based review is what turns "trusted with use" from a black box into a controllable feedback loop.

---

## 5. Synthesis: what this means for Lira's design

Research-backed rules for an adaptive-trust mechanism that satisfies ADR-0004:

1. **Track-record informs *recommendations*, never grants.** The system may compute and surface "N clean executions in category X; suggest raising the auto-allow cap / approving standing permission." The *decision* is a human action in the deterministic policy engine. (Adjustable autonomy; Lee & See.)
2. **Loosening is a policy-object edit, outside the model.** The model cannot write the policy, expand its tool list, or certify completion — the non-negotiable — because those objects are owned by the deterministic engine + human, not the model. (OPA; separation of duties.)
3. **Loosening is scoped, time-bounded, and decayable.** Standing permission is per-category, minimal, and expires unless the human renews it. No silent permanent escalation. (Least privilege; OAuth; iOS time-bounded grants.)
4. **Every grant and every consequential action is audited in an append-only log** and, for "done" claims, verified by an external non-model signal (ADR-0001's three-gate already implements the external-attestation half). The human always has the raw material to revoke or tighten. (Immutable audit; reward-hacking defense.)
5. **The human always owns the dial.** "Gets smarter with use" is realized as *the owner raising thresholds after observing good, audited behavior* — frictionless-with-use and no-self-escalation are not in tension, because the persistence of past approvals is a human-editable record, exactly as in §2.1.

---

## 6. Selected sources

- Lee, J. & See, K. (2004). *Trust in Automation: Designing for Appropriate Reliance.* Human Factors, 46(1), 50–80. — trust calibration, over/under-reliance.
- Goodrich, M., Olsen, D., & Crandall, J. (2001). *Experiments in Adjustable Autonomy.* IJCAI. — authority negotiated/transferred to human.
- Amodei, D. et al. (2016). *Concrete Problems in AI Safety.* arXiv:1606.06565. — reward hacking as the forbidden self-attestation failure mode.
- Miller, M., Yee, K.-P., & Shapiro, J. (2003). *Capability Myths Demolished.* — capability-based security, least privilege.
- Saltzer, J. & Schroeder, M. (1975). *The Protection of Information in Computer Systems.* CACM 18(7). — least privilege; reference monitor.
- Hardt, D. (Ed.). (2012). *RFC 6749: The OAuth 2.0 Authorization Framework*; RFC 7009 (token revocation). — scoped, revocable delegation.
- *Open Policy Agent* (openpolicyagent.org). — policy decision decoupled from enforcement (policy-as-code).
- Apple. *Platform privacy / Transparency, Consent, and Control* (TCC); Android runtime permissions. — user-granted, non-self-escalating, time-bounded permissions.
- Wu, Z. et al. (2023). *Avi Agent: An AI-generalist digital assistant.* arXiv:2309.12629. — human-in-the-loop autonomy gradation for a general assistant.
- Lira internal: `docs/adr/0001` (three-signal external verification), `docs/adr/0004` (non-negotiable, owner-configured autonomy thresholds).
