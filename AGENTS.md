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

## Reference

The prior Lira implementation attempt (scrapped for poor structure and unverifiable quality — see `docs/adr/0001`) lives at `/Volumes/iMac II/Lira` on an external drive. Its `VISION.md`, `PRD.md`, `DECISIONS.md`, and `docs/*` are a strong first draft for this rebuild's product and architecture thinking — read them for ideas, never copy code from them directly.
