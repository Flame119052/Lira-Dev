---
status: accepted
---

# bb-orchestrated build with mandatory CI + second-agent review + owner exercise

The prior Lira implementation attempt was scrapped as poorly structured and unverifiable. Its `AGENTS.md` already mandated a rigorous quality gauntlet (mutation testing, coverage floors, "a model saying done is not evidence"), but nothing mechanically enforced it — there was no CI, and work rotated across multiple ad hoc coding harnesses (opencode, Claude, Codex) session to session, so compliance depended entirely on whichever agent was running that day self-attesting. The owner is not a coder and had no way to independently check that.

For this rebuild: **bb** is the standing orchestrator for coding work on Lira — usually, with direct harness fallback permitted (e.g. zcode, when its free credits are available) rather than a hard rule against it. A milestone is only "done" when three independent signals agree: CI (GitHub Actions) is green, a second independent agent has reviewed the change, and the owner has personally exercised the running app. No agent's own report of completion is sufficient on its own.

This supersedes the old `AGENTS.md` §6 gate rules as an *enforcement* mechanism (their content mostly still holds as a quality bar) and supersedes old ADR-033/035/036, which assumed a Codex-specific mandatory review lifecycle — those need rewriting under this model; flagged as open work, not yet done.
