---
status: accepted
---

# Coding-agent dispatch: direct subprocess + native JSONL streams

Lira dispatches Claude Code, Codex, and opencode CLIs as direct subprocesses, parsing each one's native structured JSON status stream (`claude -p --output-format stream-json`, `codex exec --json`, `opencode run --format json`) rather than a bundled SDK or a bespoke wrapper protocol.

Reuses the owner's existing CLI logins by default; per-tool credential isolation (env/config overrides) is available when Lira shouldn't share identity with the owner's own sessions. Sandboxing is two-layered: each CLI's own tool-permission system as the inner boundary, the macOS App Sandbox as the outer one.

This is the same pattern bb itself uses to dispatch the very providers building Lira, and matches how these CLIs are natively designed to be embedded — confirmed directly, not just documented, during this project's own build process.
