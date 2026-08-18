# Research: headless coding-agent CLI dispatch

Status: research (wayfinder #15, child of #4)
Date: 2026-08-18
Applies to: Lira v1 `coding-agent-dispatch` tool capability (confirmed in scope 2026-08-17)

## Question

How can **Claude Code**, **Codex**, and **opencode** CLIs be invoked headlessly / programmatically by a native Swift app — covering (a) authentication & session handling, (b) structured, non-decorative-terminal status streams, (c) sandboxing implications, and (d) credential scoping? This is the groundwork for Lira dispatching these coding agents *directly*, as one of Lira's own tool capabilities, **not** through an intermediary orchestration layer (distinct from ADR-0001, where bb orchestrates agents to build Lira itself).

## TL;DR / recommendation

All three CLIs expose a headless mode that emits **newline-delimited JSON (NDJSON/JSONL)** status streams over `stdout`, with the interactive/TUI decorations suppressed. A native Swift app can therefore spawn each CLI as a subprocess (`Process`), read the JSONL stream line-by-line, and render progress without parsing ANSI. The cleanest integration surface differs per tool:

| Tool | Headless entry | Structured stream | Best-for-Swift route |
|------|----------------|-------------------|----------------------|
| Claude Code | `claude -p ... --output-format json\|stream-json` | JSON result object / NDJSON event stream | subprocess with `-p --output-format stream-json --verbose`, or the Node/TS Agent SDK (requires embedding Node) |
| Codex | `codex exec --json` | NDJSON (thread/turn/item events) | subprocess `codex exec --json` (no official non-Rust SDK in the CLI path; `@openai/codex` SDK is Rust/Node) |
| opencode | `opencode run --format json` / `opencode serve` / `opencode acp` | NDJSON (step/text events) + HTTP server API + ACP | subprocess `run --format json`, or persistent `serve` HTTP endpoint, or `acp` Agent Client Protocol |

**Recommendation:** For a native Swift app, the lowest-friction, most vendor-neutral path is to **wrap the CLI binaries as subprocesses** and consume their JSONL streams. Avoid depending on Node/TS SDKs unless the app already bundles a Node runtime, since all three CLIs are distributed as standalone binaries but their "SDKs" live in the Node/TS/Python ecosystem. Where long-lived, warm dispatch is needed, opencode's `serve` HTTP interface and ACP are the most embeddable; Codex and Claude Code prefer one-shot subprocess invocations with session IDs for continuation.

---

## 1. Authentication & session handling

### 1.1 Claude Code

- **Auth modes:** OAuth (ChatGPT-style login with an Anthropic account, stored via the system keychain on macOS) or API key (`ANTHROPIC_API_KEY`). `--bare` mode **never** reads OAuth credentials or the system keychain — it strictly uses `ANTHROPIC_API_KEY` or an `apiKeyHelper` supplied via `--settings`. Third-party providers (Bedrock/Vertex/Foundry) read their own provider credentials. [docs: headless/bare mode]
- **Credential storage:** interactive auth persists to the user profile (keychain; `~/.claude/` config). `--bare` is the recommended mode for scripted/SDK calls and "will become the default for `-p` in a future release." [docs: headless]
- **Session handling:** each `-p` run produces a `session_id`. Use `--continue` to resume the most recent conversation, or `--resume <session_id>` to resume a specific one. Session IDs are resolvable across directories on the same machine. `--fork-session` creates a new ID instead of reusing. [docs: headless; CLI reference]
- **Exit codes:** 0 on success, non-zero on run failure; failures (e.g., missing auth) are printed as the JSON `result` on stdout, not stderr. Invalid flags error on stderr before the run. SIGTERM aborts the turn, terminates the Bash command tree, runs `SessionEnd` hooks, exits 143. [docs: headless]

### 1.2 Codex

- **Auth modes:** ChatGPT account (OAuth) or API key (requires explicit setup). `codex login` / `codex logout` manage credentials. [GitHub README; Codex docs]
- **Credential storage:** `~/.codex/auth.json` (verified present, mode `0600`). `$CODEX_HOME` overrides the config + auth directory. `codex exec --ignore-user-config` skips `$CODEX_HOME/config.toml` but "auth still uses `CODEX_HOME`." [codex exec --help]
- **Session handling:** `codex exec` emits a `thread.started` event with a `thread_id`; `codex exec resume --last` or `--id` resumes prior sessions. `--ephemeral` runs without persisting session files. [codex exec --help]

### 1.3 opencode

- **Auth modes:** provider-based. `opencode auth login` configures API keys for any provider in the models.dev catalog; keys stored in `~/.local/share/opencode/auth.json` (verified present, mode `0600`); also reads keys from environment or project `.env`. `opencode auth list/logout`. [opencode docs: CLI]
- **Credential storage:** `~/.local/share/opencode/auth.json`. Config via `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT`. [opencode docs: CLI, env vars]
- **Session handling:** sessions have IDs (`ses_...`); `-c/--continue` resumes last, `-s/--session <id>` resumes a specific one, `--fork` forks. `opencode session list`, `opencode export <sessionID>` (JSON, with `--sanitize` to redact secrets). Server mode supports HTTP basic auth via `OPENCODE_SERVER_PASSWORD` (user `opencode`). [opencode docs: CLI; verified in help]

---

## 2. Structured status streams (non-decorative terminal text)

All three support machine-readable output. Verified firsthand by running trivial prompts against installed CLIs (versions: claude 2.1.233, codex-cli 0.147.0, opencode 1.18.18).

### 2.1 Claude Code

- `--output-format json`: a **single** JSON result object with `type:"result"`, `result` (the final text), `session_id`, `total_cost_usd`, per-model cost breakdown, `usage` (tokens), `permission_denials`, `is_error`, `stop_reason`. Verified example field set. [docs: headless "Get structured output"]
- `--output-format stream-json` **requires `--verbose`** under `-p` (verified: without `--verbose` it errors). Emits NDJSON events: `system/hook_started`, `system/hook_response`, `system/init` (model, tools, MCP servers, plugins, `permissionMode`, `apiKeySource`), `assistant` message objects, `rate_limit_event`, and a final `result`. Add `--include-partial-messages` for token deltas, `--include-hook-events` for hook lifecycle, `--forward-subagent-text` to see nested-subagent transcripts. [docs: headless; CLI reference; verified]
- **JSON Schema validation:** `--json-schema '<schema>'` with `--output-format json` yields schema-conformant output in the `structured_output` field. [docs: headless]
- The last line of a `stream-json` stream is a `result` message with final text, cost, and session metadata. [docs: headless]

### 2.2 Codex

- `codex exec --json` prints **NDJSON** to stdout (verified): `thread.started` (with `thread_id`), `item.completed` events (each carrying an `item` with `type:"agent_message"`, `text`, or `type:"error"`), `turn.started`, `turn.completed` (with `usage`/tokens). `-o/--output-last-message <file>` writes the final agent message to a file. `--output-schema <file>` validates the final response against a JSON Schema. [codex exec --help; verified]

### 2.3 opencode

- `opencode run --format json` prints **NDJSON** (verified): `step_start`, `text` (with `part.text`), `step_finish` (with `reason`, `tokens`, `cost`), each tagged with `sessionID`. The default `--format` is human-formatted. [opencode docs: CLI; verified]
- **Server mode:** `opencode serve` starts a headless HTTP server (the full HTTP interface is documented under the Server/SDK docs), enabling attach (`opencode run --attach http://localhost:4096`) or direct HTTP calls. `OPENCODE_SERVER_PASSWORD` enables basic auth.
- **ACP:** `opencode acp` starts an Agent Client Protocol server speaking nd-JSON over stdio — a standardized bidirectional interface ideal for embedding.
- **Export:** `opencode export [sessionID] --sanitize` dumps session data as JSON for persistence/audit.

---

## 3. Sandboxing implications

The three tools take **different philosophies** to sandboxing, which matters when Lira dispatches agents that will mutate a user's repo.

### 3.1 Claude Code

- Permission model is **allowlist-based**: `--permission-mode` (`default`, `acceptEdits`, `dontAsk`, `plan`, `auto`, `bypassPermissions`) plus `--allowedTools`/`--disallowedTools` with permission-rule syntax (e.g., `Bash(git diff *)`). For `-p`, the default starting mode is **Manual**; pass the mode explicitly. [docs: headless, permission modes]
- `--dangerously-skip-permissions` / `--allow-dangerously-skip-permissions`: bypass all checks; the docs explicitly recommend these **only for sandboxes with no internet access** — i.e., rely on an *external* OS/app sandbox rather than the tool's own. [CLI reference]
- `dontAsk` is recommended for locked-down CI runs (denies anything not in `permissions.allow` or the read-only command set). [docs: headless]
- **Implied for Lira:** prefer `--permission-mode dontAsk` or a tight `--allowedTools` allowlist, plus `--add-dir` to restrict filesystem scope; use the external App Sandbox (macOS) as the outer boundary rather than `--dangerously-skip-permissions`.

### 3.2 Codex

- First-class, granular sandbox: `-s/--sandbox` with modes `read-only`, `workspace-write`, `danger-full-access` (a.k.a. `sandbox_permissions` config). Additional writable dirs via `--add-dir`. `--approve-for-me` routes approvals through the workspace-write sandbox automatically. [codex exec --help]
- `--dangerously-bypass-approvals-and-sandbox` is explicitly intended "solely for running in environments that are externally sandboxed." [codex exec --help]
- **Implied for Lira:** Codex's sandbox is the most turnkey — `read-only` or `workspace-write` are sensible defaults; grant extra writable paths deliberately.

### 3.3 opencode

- Permission flags: `--auto` auto-approves anything not explicitly denied (the help labels it "dangerous!"); the `--permission-mode`-equivalent is configured per-agent via `opencode agent create --permissions bash,read,edit,...` (anything omitted is denied). Policies documented under Permissions/Policies. [opencode docs: CLI, agents]
- `serve`/`web` can be network-exposed; `OPENCODE_SERVER_PASSWORD` provides basic auth, and default hostname is `127.0.0.1`. [opencode docs: CLI]
- **Implied for Lira:** construct agents with a minimal `--permissions` allowlist; avoid `--auto`; bind `serve` to loopback with a password if used as a persistent endpoint.

**Sandboxing takeaway:** For every tool the intended pattern is *defense-in-depth* — use the tool's own permission/sandbox mode as the inner guardrail and the macOS App Sandbox / seatbelt profile as the outer one. Prefer the tool's restrictive modes (`dontAsk`, `read-only`/`workspace-write`, minimal agent permissions) over the "dangerously skip" flags, which are only for externally-sandboxed hosts.

---

## 4. Credential scoping

Lira is a local-first macOS app dispatching coding agents on the user's behalf. Credential scoping decisions:

- **Reuse the user's existing sessions.** All three default to the user's real credential stores (`~/.claude` keychain / `~/.codex/auth.json` / `~/.local/share/opencode/auth.json`). Reusing them means Lira honors the user's existing provider logins and quotas, and needs **no** credential handling of its own. The trade-off is that Lira's agent runs share identity/limits with interactive use.
- **Isolate via env/config overrides** when Lira must not touch the user's primary identity:
  - Claude Code: `--bare` avoids OAuth/keychain reads; supply a scoped `ANTHROPIC_API_KEY`, or an `apiKeyHelper`/`--settings`; `CLAUDE_CODE_SIMPLE=1` is set by `--bare`. [CLI reference]
  - Codex: point `$CODEX_HOME` at a per-app directory to isolate both `auth.json` and config. [codex exec --help]
  - opencode: `OPENCODE_CONFIG`/`OPENCODE_CONFIG_DIR` relocate config; auth.json is provider-keyed, so adding a provider token rather than reusing the global file keeps the app's usage separate. [opencode docs: CLI]
- **Never store/transcribe tokens into Lira's own store.** Prefer env-var injection at spawn time, or a dedicated, app-managed credential file scoped by a per-app `CODEX_HOME`/config dir, protected with Keychain permissions, rather than copying secrets from the CLI's stores.
- **Per-run cost attribution** is available from the streams: Claude Code's `total_cost_usd`, Codex `turn.completed.usage`, opencode `step_finish.cost` — so Lira can log spend per dispatched agent without extra API calls. [docs: headless; verified]

---

## 5. Concrete integration pattern for a native Swift app

```swift
// One-shot Claude Code dispatch, streaming NDJSON to a handler.
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
proc.arguments = [
    "-p", prompt,
    "--output-format", "stream-json",
    "--verbose",
    "--permission-mode", "dontAsk",
    "--allowedTools", "Read,Glob,Grep,Bash(git diff *)",
    "--add-dir", workspace.path,
]
// set environment: ["ANTHROPIC_API_KEY": scopedKey]  (or reuse OAuth in non-bare mode)
// read stdout line-by-line; each line is a JSON event; forward to UI/model.
// on completion, read proc.terminationStatus and the final "result" event.
```

The same shape applies to `codex exec --json` and `opencode run --format json`. For a warm long-running service, `opencode serve` + HTTP (or `opencode acp` stdio) avoids per-call cold starts; for Codex/Claude Code, reuse session/thread IDs across invocations instead of keeping the process alive.

---

## Sources

- Anthropic Claude Code — "Run Claude Code programmatically" (headless/`-p`): https://docs.anthropic.com/en/docs/claude-code/headless
- Anthropic Claude Code — Agent SDK overview: https://docs.anthropic.com/en/docs/claude-code/sdk (note: SDK is Python/TypeScript only; "To drive the same agent loop from another language, run the CLI as a subprocess")
- Claude Code CLI reference (`-p`, `--output-format`, `--permission-mode`, `--bare`, auth): https://docs.anthropic.com/en/docs/claude-code/cli-reference
- OpenAI Codex — repo/README (install, auth, login/logout): https://github.com/openai/codex
- OpenAI Codex — auth docs (ChatGPT account vs API key): https://developers.openai.com/codex/auth
- opencode — CLI docs (`run`, `serve`, `auth`, `session`, `export`, `acp`, env vars): https://opencode.ai/docs/cli
- opencode — Server / HTTP interface: https://opencode.ai/docs/server ; SDK: https://opencode.ai/docs/sdk
- Verified by direct execution 2026-08-18 (claude 2.1.233, codex-cli 0.147.0, opencode 1.18.18) for: JSON/NDJSON stream shapes, `stream-json --verbose` requirement, auth file locations (`~/.codex/auth.json`, `~/.local/share/opencode/auth.json`), sandbox flags, and session/continuation semantics.
