# Lira agent workflow

Provider-neutral entry point for any coding harness working on Lira (Claude Code, Codex, opencode, others via bb). `CLAUDE.md` exists alongside this file for whatever is genuinely Claude-Code-specific; everything else lives here.

The full binding execution workflow (review lifecycle, quality gates, milestone process) is not written yet — see `docs/adr/0001-bb-orchestrated-build-with-mandatory-independent-verification.md` for the standing trust model (CI green + second-agent review + owner exercises the app) this workflow needs to be built around. Rewriting that into a working process is the first task after project setup, not yet done.

## Agent skills

### Issue tracker

Issues and design tickets live as GitHub issues on this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Standard five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), unchanged from defaults. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Working agreement

- **Owner is not a coder.** Explain any technical/process term in plain language before asking for a decision — never assume familiarity, even with common software terms.
- **Every question to the owner must include a recommended option**, clearly marked, with the reasoning behind it — never present a bare list of choices and leave the owner to adjudicate alone. This applies everywhere, not only inside `/grill-with-docs`/`/wayfinder`-style interviews.
- **Watch for overengineering, actively, not just when the owner flags it.** Before proposing a technical approach, ask whether a simpler one already covers the real requirement (e.g. Tailscale already solving NAT traversal made a full WebRTC stack unnecessary for voice — see `docs/adr/0008`). Prefer the option with less total dependency surface when it genuinely covers the need, and say so explicitly when a fancier option was considered and rejected for this reason.

## Reference

The prior Lira implementation attempt (scrapped for poor structure and unverifiable quality — see `docs/adr/0001`) lives at `/Volumes/iMac II/Lira` on an external drive. Its `VISION.md`, `PRD.md`, `DECISIONS.md`, and `docs/*` are a strong first draft for this rebuild's product and architecture thinking — read them for ideas, never copy code from them directly.
