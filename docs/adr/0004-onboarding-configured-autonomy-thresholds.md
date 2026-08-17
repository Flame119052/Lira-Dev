---
status: accepted
---

# Owner-configured autonomy thresholds, set during onboarding

The old design already routes every real-world effect through deterministic policy, never model self-approval (non-negotiable: "a model cannot approve itself, expand its tools, or certify its own completion"), with risk-tiered auto-allow for eligible low-risk actions. What was undecided: who sets the thresholds, and when.

Decision: the owner sets their own autonomy/risk-tolerance thresholds explicitly during onboarding — which categories of action (spending money, deleting things, sending messages, etc.) auto-execute versus always require a real-time approval prompt — rather than the thresholds being a fixed, developer-chosen default buried in settings. This is a first-class onboarding step, not an afterthought, because the owner considers it one of the most important trust decisions in the whole product.

This doesn't loosen the existing non-negotiable: the model still never expands its own tools or approves its own actions. Only the deterministic policy engine acts on the owner's configured thresholds, and the owner can revisit them later — onboarding sets the initial values, not a one-time irreversible choice.
