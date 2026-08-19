# Research: multi-provider model orchestration — primary can delegate to any provider

**Ticket:** [#29 — Research bb-style multi-provider model orchestration patterns](https://github.com/Flame119052/Lira-Dev/issues/29) (child of [#4 Lira v1 architecture map](https://github.com/Flame119052/Lira-Dev/issues/4))  
**Date:** 2026-08-19  
**Branch:** `research/provider-abstraction`  
**Status:** research — no code change, informs future ADR

> **One-line gist:** Lira can keep one stable identity (ADR-007) while any foreground or worker session delegates to any model provider, by reusing the bb pattern (primary identity + `ModelProvider`/`WorkerAdapter` ports) and invoking provider CLIs/APIs via direct subprocess + native JSONL streams (ADR-0010) — with ACP as the portable worker boundary, not a second identity.

---

## 1. Question

How to build a provider-agnostic "primary model, can delegate to any other provider" architecture for Lira itself — a native macOS app, not built on bb — that mirrors how bb orchestrates this project's build:

- a chosen primary agent/provider that retains its own identity,
- can spawn or dispatch sub-tasks to *any* other provider (local models, cloud models, opencode Go specifically),
- without changing its own identity.

Cover:

1. the Agent Client Protocol (ACP, used by bb for opencode/cursor/grok integrations) and any public spec/documentation for it — what it actually standardizes;
2. how other multi-provider AI orchestration frameworks keep one stable identity across swappable backends;
3. how this reconciles with Lira's already-decided architecture — ADR-007 in the reference repo ("One Lira identity across many providers", read directly from `/Volumes/iMac II/Lira/DECISIONS.md`) and ADR-0010 in this repo (direct subprocess + native JSONL streams).

---

## 2. What bb itself does today (the lived pattern this research grounds)

This is observable from running `bb guide` and `bb status` inside this worktree — no external fetch required.

- **Providers are pluggable backends.** `bb provider list` / `bb provider models` enumerates built-ins (`claude-code`, `codex`) and any ACP agent found on `PATH` (opencode, Cursor, Grok, Hermes, etc.). Each provider exposes its own model catalog. Model selection is per-thread and sticky for that thread's lifetime (`bb thread update --model`).

- **A primary identity spawns children on any provider.** The canonical delegation primitive is:

  ```bash
  bb thread spawn --parent-self --provider <any> --model <any> --prompt "..."
  ```

  `--parent-self` parents the new thread to the current thread (`BB_THREAD_ID`). The parent remains the owner of the task; the child is a bounded sub-task that reports back via lifecycle notifications (completes, fails, interrupted). From `bb guide threads`:

  > "Threads can have a parent-child relationship. The parent coordinates the child and receives lifecycle notifications when it completes, fails, or is interrupted."

  Permission mode is a hard ceiling: a child's requested mode can lower but never exceed the parent's, so a sandboxed primary cannot spawn a full-access child.

- **Worktree/environment is explicit.** `--new-environment worktree` or `--environment <id>` controls the workspace the child sees. Multiple threads can share an environment. This is how bb avoids "one model per agent" — agents are state in the orchestrator, not processes that own truth.

- **ACP is the portable boundary for third-party agents.** From `bb guide providers`:

  > "Known ACP agents can appear automatically when their CLI is installed on the host. For example, opencode, omp, Grok Build's grok CLI, or Hermes' hermes CLI on PATH appears as provider `acp-opencode`, `acp-omp`, `acp-grok`, or `acp-hermes-agent`.  
  > ACP providers discover models from the agent itself."

  bb applies `selected model` to the ACP session before the first prompt. `acp-opencode` models mirror the OpenCode catalog.

**What Lira should borrow:** parent-owned identity and lifecycle — not provider-owned session ownership — plus explicit capability scoping per dispatch. What Lira should *not* borrow at runtime is bb itself: Lira needs its own version of this pattern by directly invoking provider CLIs/APIs, exactly as ADR-0010 already decided for coding-agent dispatch. bb is the build-time orchestrator; Lira's runtime orchestrator lives in `LiraCore` / `LiraBonsaiService`.

---

## 3. Agent Client Protocol (ACP) — what it actually standardizes

### 3.1 Does a public spec exist?

Yes. ACP is an open, Apache-2.0-licensed protocol maintained at:

- **Specification repository:** `agentclientprotocol/agent-client-protocol` on GitHub
- **Pinned snapshot used by Lira:** schema 1.19.0, tag `schema-v1.19.0`, commit `a213df5` — recorded in the reference repo's `docs/UPSTREAMS.md` §3.1 as the "Portable `WorkerTransport` for agents that implement ACP" (see Sources below)
- **Public documentation site:** `agentclientprotocol.com` (redirects to the GitHub repo's README/spec; `WebFetch` of that URL redirects to the GitHub repo — same authoritative source)

This is not a private bb abstraction. bb consumes the public schema; Lira's reference architecture also names it as the portable agent boundary (`WRK-02` in the reference PRD, ADR-016/UPSTREAMS §3.1).

### 3.2 What ACP standardizes (and what it deliberately does not)

ACP is intentionally analogous to LSP (Language Server Protocol) and MCP (Model Context Protocol), but for *agent sessions* rather than editor features or tool catalogs. From the spec and UPSTREAMS §3.1:

**Transport:** JSON-RPC 2.0 over stdio (stdin/stdout), framed, bounded messages. The client (Lira / bb) spawns the agent as a child process and speaks JSON-RPC to it.

**Lifecycle that is standardized:**

| Area | What the spec defines |
|---|---|
| **Version negotiation** | `initialize` / `initialized` handshake with protocol version and capability exchange |
| **Session management** | `session/new`, `session/load`, `session/fork`, heartbeat, explicit `session/cancel` |
| **Prompt / turn** | `session/prompt` (structured prompt + context), streaming `session/update` events (deltas) |
| **Tool interaction** | Tool call requests and results as typed events, not free-form terminal text |
| **Permissions** | `permission_request` events that pause the agent until the client approves/denies — Lira's `WorkerAdapter` maps these to its `permission_request` queue (ADR-034) |
| **File / edit operations** | Structured file read/write/edit intents with bounded content |
| **Artifacts & evidence** | Exact artifact transport (files, diffs, test output) alongside narration — not a restyled summary |
| **Cancellation & restart** | Cooperative cancellation, restart, and resume semantics per session |

**What ACP does NOT standardize:**

- Identity, memory, goals, policy, or completion semantics — those remain Lira-owned (ADR-007). ACP transports a *job*, not a product truth.
- Which model is inside the agent — ACP agents are model-agnostic harnesses (opencode, Cursor, etc.). The `model` selection is a separate client concern (which is why `bb provider models acp-opencode` enumerates models *from the agent* and `bb thread spawn --model` sets it before `session/new`).
- Tool catalog semantics beyond the envelope — MCP remains the tool boundary; ACP is the agent boundary. Lira's docs keep this split explicit: "ACP as the portable agent boundary and MCP the tool boundary" (UPSTREAMS §3.1, ADR-016).

**Framing contrast for Lira's choice:** ACP is the preferred *general-worker* boundary for agents that already implement it (opencode, etc.). For first-party CLIs with richer native protocols (Codex app-server, Claude Code `--output-format stream-json`), Lira uses the provider's native structured stream directly — ACP is a fallback portability layer, not a replacement for native fidelity. This is ADR-016/ADR-033's position and UPSTREAMS §4.8's bake-off table ("Goose / OpenCode / Claude Agent SDK / Codex CLI / Claude CLI — all behind `WorkerAdapter`").

### 3.3 Why ACP matters for "primary can delegate to any provider"

Without ACP, each delegation target would need a bespoke parser for decorative terminal output — fragile, unversioned, and impossible to gate on cancellation/permission. With ACP:

- the primary (`LiraCore` + `LiraBonsaiService`) keeps one stable identity and issues bounded jobs via a single typed contract (`WorkerAdapter`);
- any ACP-compliant agent (opencode for local Qwen, a future harness, a paired `LiraNodeService`) plugs in without changing Lira's job-store schema, lifecycle state machine, or evidence envelope;
- provider-specific CLIs that *do* offer richer streams (Codex app-server) can still be used natively behind the same port, with ACP as the portability seam Lira falls back to.

---

## 4. How other multi-provider systems keep one identity across swappable backends

External research synthesis — each bullet cites a public source (full URLs in §7).

### 4.1 The common pattern: owned three-layer separation

Across LiteLLM proxy, Vercel AI SDK, LangChain, and OpenRouter, the systems that successfully keep one product identity while swapping providers all separate three things that Lira's ADRs already separate by name:

1. **Owned identity & persona assembly — never delegated.** The product (not the model) assembles the system prompt, persona constitution, memory, and user controls into a bounded envelope per turn. In Lira this is the five-layer personality envelope (`ADR-018`, `docs/PERSONALITY_AND_MEMORY.md` + `docs/prompting/*`): immutable constitution > user controls > approved learned preferences > relationship continuity > ephemeral context, assembled deterministically by `LiraCore`. No multi-provider router in the wild delegates this to the backend model — the router is explicitly *below* identity.

2. **Normalized request/response envelope behind a port.** The product defines one typed request shape and one typed chunk/error shape; each provider adapter translates to/from that shape. Examples:
   - **LiteLLM** exposes an OpenAI-compatible `/chat/completions` surface and normalizes 100+ providers to that shape behind the proxy (`litellm.ai`, `github.com/BerriAI/litellm`).
   - **Vercel AI SDK** exposes `LanguageModel` as a provider-neutral interface with provider-specific adapters (`ai` SDK docs: Provider Management / `ai-sdk-core`).
   - **LangChain** exposes `ChatModel` / `BaseChatModel` with `invoke`/`stream` normalized across providers (`python.langchain.com/docs/concepts/chat_models`).
   - **OpenRouter** normalizes 200+ models behind one OpenAI-compatible API and returns a stable `model` + `provider` + usage envelope.

   Lira's analog is `ModelProvider` (for the foreground/primary reasoning path) and `WorkerAdapter` (for specialist workers) — both ports, not concrete SDKs. The envelope already separates narration from artifacts/evidence (ADR-007 Consequence).

3. **Capability manifests and per-call policy.** The product probes or declares what each provider *can* do (tools, structured output, context length, cost, latency, privacy boundary) and runs deterministic policy *before* dispatch — never inside the model context. Lira already does this via `docs/AGENT_RUNTIME.md` §7 capability routing and `docs/MODEL_RUNTIME.md` §6 routing, with deterministic policy (ADR-006) as the authority for scope, risk, and approvals.

### 4.2 How provenance stays honest when providers change

A recurring failure mode in multi-provider wrappers is "the cheapest model this week becomes the narrator" and silently rewrites history. The durable pattern:

- **Provider provenance is metadata, not identity.** Store `provider_id`, `model_id`, `model_revision`, `artifact_hash`, `event_schema_version` on every turn/artifact, but render history from Lira-owned records — never re-derive persona from the provider's own memory. LiteLLM's proxy logs `model` + `custom_llm_provider` per request for exactly this reason; Vercel's SDK surfaces `provider` and `modelId` on every stream chunk alongside the normalized text.
- **No silent restyling through a small local model.** ADR-007 already forbids this ("Do not run every Codex/Claude result through a small local model merely to restyle it") — the same rule that keeps LiteLLM/OpenRouter wrappers from laundering worker output through a cheaper summarizer. Worker artifacts are stored verbatim; optional concise narration is a *separate* envelope field.

### 4.3 Concrete provider-routing patterns worth borrowing

| Pattern | Where it is established | How Lira maps it |
|---|---|---|
| **Unified proxy with per-route model list + fallback** | LiteLLM proxy `router` (+ `fallbacks` + `model_list`) | Lira's `ModelProvider` routing table + deterministic fallback chain in `docs/MODEL_RUNTIME.md` §6 (local → private node → named cloud). Fallback is policy-gated, not automatic inside the model call. |
| **Provider-agnostic stream with typed `onChunk` / `onFinish`** | Vercel AI SDK `streamText` | Lira's `ModelEventKind` (delta, reasoningDelta, toolCall, finish) already mirrors this — one normalized stream, provider-specific parsing underneath. |
| **ChatModel abstraction + `withStructuredOutput`** | LangChain | Lira's `LiraInferenceService` structured-output path (MLX Swift LM tool/structured-output gate in ADR-009). The port owns the schema; providers adapt to it. |
| **Cost/latency/privacy labels per model** | OpenRouter model catalog (`openrouter.ai/models`) + LiteLLM `model_info` | Lira's `model_manifest` + capability/resource manifest per `ModelProvider` entry (already in `docs/MODEL_RUNTIME.md` §9 / `docs/RESOURCE_BUDGETS.md`). |

---

## 5. Reconciliation with Lira's already-decided architecture

### 5.1 ADR-007 exact text (reference repo, `/Volumes/iMac II/Lira/DECISIONS.md`)

> ### ADR-007 — One Lira identity across many providers
>
> **Status:** Accepted  
> **Decision:** Identity, memory, relationship continuity, policy, and evidence are Lira-owned. `ModelProvider` and `WorkerAdapter` expose capabilities and provenance. A provider does not become Lira's identity.  
>
> **Why:** The strongest or cheapest provider will change. Local models will be smaller. Worker output must remain exact. A stable relationship must not disappear when routing changes.  
>
> **Consequence:** The response envelope separates narration from artifacts/evidence. Do not run every Codex/Claude result through a small local model merely to restyle it.

This is the *non-negotiable invariant* (§3.1): "Lira owns identity, policy, memory semantics, durable goals, and completion — not any model or framework." It is also the lens for every multi-provider choice below.

### 5.2 ADR-0010 in this repo (coding-agent dispatch)

> # Coding-agent dispatch: direct subprocess + native JSONL streams  
> Lira dispatches Claude Code, Codex, and opencode CLIs as direct subprocesses, parsing each one's native structured JSON status stream (`claude -p --output-format stream-json`, `codex exec --json`, `opencode run --format json`) rather than a bundled SDK or a bespoke wrapper protocol.  
> Reuses the owner's existing CLI logins by default; per-tool credential isolation (env/config overrides) is available when Lira shouldn't share identity with the owner's own sessions. Sandboxing is two-layered: each CLI's own tool-permission system as the inner boundary, the macOS App Sandbox as the outer one.  
> This is the same pattern bb itself uses to dispatch the very providers building Lira, and matches how these CLIs are natively designed to be embedded — confirmed directly, not just documented, during this project's own build process.

### 5.3 How the new requirement reconciles — point by point

| Requirement | ADR-007 constraint | ADR-0010 constraint | Reconciliation |
|---|---|---|---|
| **Primary can delegate to any provider (local, cloud, opencode Go)** | Provider never becomes Lira's identity; `ModelProvider`/`WorkerAdapter` are capability + provenance only | Dispatch via direct subprocess + native JSONL where available | **Alignment, not conflict.** Delegation is via `ModelProvider`/`WorkerAdapter` ports; each dispatch is a bounded job with Lira-owned prompt assembly and evidence. The primary's persona envelope is assembled once by Lira and passed *in* — not re-derived by the delegate. |
| **Stable relationship across provider swaps** | Relationship continuity is Lira-owned memory (ADR-018 five layers), not provider session memory | Worker output is exact; no mandatory restyle | Lira keeps conversation/memory in its own SQLite/FTS store (ADR-002/ADR-003). Swapping from Qwen3.5-4B local to a cloud model or opencode-forked worker changes the `provenance` field, not the `persona_revision` or user-facing name/voice. |
| **ACP for opencode/cursor/grok-style agents** | ACP is a `WorkerTransport` capability, not proof a worker is safe (UPSTREAMS §3.1) | ACP is *one* dispatch mechanism among several (native JSONL preferred where richer) | ACP is adopted as the *portable* worker boundary (UPSTREAMS Adopt), native Codex app-server / Claude stream-json as the *rich* boundary. Both sit behind the same `WorkerAdapter`. No second identity is introduced. |
| **No dependency on bb at runtime** | Lira's durable core owns lifecycle; no upstream may own goals/effects/completion (UPSTREAMS §2) | Direct subprocess invocation, no bundled SDK | Correct: Lira reimplements the *pattern* (parent-owned lifecycle, typed events, permission callback, worktree isolation) without depending on bb's daemon. bb is build-time evidence that the pattern works. |
| **Local-first with cloud as optional delegate** | "The strongest or cheapest provider will change" — ADR-007 anticipates routing changes | Reuses owner's existing CLI logins; per-tool credential isolation when needed | Multi-provider routing is policy-gated: `Local` (MLX Swift LM) → `Private Remote` (paired node) → `Cloud` (user-supplied credential) — never silently, always with cost/retention disclosure (SEC-06). The `ModelProvider` manifest marks which routes require credentials. |

**One sentence reconciliation:** ADR-007 says *who Lira is* never changes when the model does; ADR-0010 says *how Lira talks to any model* is direct subprocess + typed streams — the new "primary delegates to any provider" requirement is the composition of both: keep identity in Lira, dispatch via ports, parse typed events, store provenance.

### 5.4 What does NOT need to change

- **No new identity concept.** The five-layer persona + deterministic assembler already solves "one Lira across many providers." The research found no multi-provider system that keeps a stable product identity *without* an owned assembler — LiteLLM, Vercel, LangChain, OpenRouter all keep it outside the provider.

- **No new IPC for the primary reasoning path.** `LiraInferenceService` (XPC/Unix-socket, `ModelRuntimePort`) stays the primary decode lane. Multi-provider delegation for the *foreground* path is a `ModelProvider` switch (same IPC, different adapter), not a new process.

- **No second resident model.** ADR-008 ("Zero or one custom local generative model; one decode lane") is unchanged. Delegating to a cloud model or a subprocess worker does not add a resident weight set. `LiraBonsaiService` remains the only bounded CPU-only companion (ADR-032), not a second generative peer.

---

## 6. Recommended shape for Lira's own provider-agnostic delegation

This is the minimal architecture that satisfies the research question without overengineering — explicitly preferring less dependency surface when it covers the need.

### 6.1 Two ports, one envelope

```
LiraCore / LiraBonsaiService
   │
   ├─ ModelProvider  ──► foreground reasoning (primary can change per turn)
   │     ├─ SystemModelProvider  (Apple Foundation Models, optional)
   │     ├─ CustomModelRuntime   (MLX Swift LM — LiraInferenceService)
   │     ├─ CloudModelAdapter    (OpenAI Responses / Anthropic Messages, owned URLSession)
   │     └─ PrivateNodeModel     (paired Mac llama.cpp server, OpenAI-compatible)
   │
   └─ WorkerAdapter  ──► specialist workers (coding, browser, general)
         ├─ CodexAppServerAdapter   (native app-server JSON-RPC)
         ├─ ClaudeStreamJsonAdapter (claude -p --output-format stream-json)
         ├─ AcpAdapter              (any ACP agent — opencode, Cursor, Grok)
         └─ FramedJsonlAdapter      (minimal fixture, fallback)
```

Both ports share:

- **One normalized envelope:** `{ narration, reasoning?, toolCalls, artifacts[], evidence, provenance{provider, model, revision, artifactHash}, usage }` — narration and artifacts are never conflated (ADR-007).
- **One policy gate:** deterministic `Policy` (ADR-006) decides *whether* a dispatch is allowed and at what risk tier, *before* any prompt is rendered. Providers never approve themselves.
- **One resource gate:** `One resource governor` (ADR-022) admits/evicts dispatch like any heavy background job; yellow pressure halts new worker admission, critical pressure unloads the runtime.

### 6.2 How bb's `spawn --parent-self --provider X` maps to Lira

| bb primitive | Lira equivalent | Notes |
|---|---|---|
| `bb thread spawn --parent-self` | `LiraCore.createAttempt(goalId, dispatch{provider, model, prompt})` — parent `goal`/`run` owns the attempt; delegate's `worker_session`/`model_turn` is a child row | Durable in SQLite (ADR-003); heartbeat/lease makes it recoverable |
| `--provider X --model Y` | `ModelProviderId` / `WorkerAdapterId` + `ModelId` in the routing table | Resolved by deterministic router (`docs/MODEL_RUNTIME.md` §6, `docs/AGENT_RUNTIME.md` §7), not by the model itself |
| `--environment` / worktree | Disposable worktree per worker session (`docs/AGENT_RUNTIME.md` §3.6, §7.6) | Each worker gets a narrow filesystem scope; LiraCore verifies via independent observation (ADR-005) |
| `permission_request` event | `WorkerAdapter.permissionRequest` → `LiraCore` permission queue (ADR-034) → foreground turn fold-in or proactive fallback | The delegate never self-approves; policy + owner approval is the only path for Risk-2/3 effects |
| `stream-json` / `app-server` events | Normalized `ModelEventKind` / `WorkerEvent` stream | Parse typed events, never decorative terminal text (ADR-016/033) |
| `bb thread wait / log` | `LiraCore` attempt state machine (`proposed → approved → started → committed/failed/uncertain`) | At-least-once effects with uncertainty (ADR-004) — delegates can die after a real-world effect but before commit |

### 6.3 Local-model delegation specifics (opencode Go path)

The ticket singles out "opencode Go specifically." From reference `docs/UPSTREAMS.md` §4.8 and bb's `acp-opencode` provider:

- **Dispatch:** `AcpAdapter` spawns the `opencode` binary (forked build that strips OpenCode's own auth layer and injects a `LiraCore` IPC adapter — ADR-033 amendment) and speaks ACP JSON-RPC over stdio. OpenCode's built-in context management is accepted but bounded (75%-of-allocated compaction, large results as artifact references — ADR-033 amendment).
- **Model inside opencode:** routing chooses Qwen3.5-4B local for simple tasks, routed cloud model for complex — or a user-pinned background-coding model preference, independent of the foreground model choice.
- **Tools for this path:** `browser-use` is registered as an OpenCode tool only for the opencode-forked worker; it does not leak into other providers' tool menus (ADR-033).
- **No second resident generative model:** opencode's process is a *worker*, not a second foreground decoder — it yields to foreground responsiveness (ADR-008/022) and is pause/evictable like any worker session.

### 6.4 The smallest viable increment

1. **Keep `ModelProvider` as the foreground abstraction** — adding a cloud/private-node adapter behind it is a routing-table change, not a new IPC.
2. **Keep `WorkerAdapter` with `AcpAdapter` as the portable worker seam** — opencode and any future ACP agent plug in there without touching the job-store schema.
3. **Add a deterministic router** (already described in `docs/MODEL_RUNTIME.md` §6 / `docs/AGENT_RUNTIME.md` §7) — table-driven, no model call to decide routing.
4. **Measure.** Follow UPSTREAMS §7 candidate evaluation contract for every new adapter (p50/p95 latency, RSS, cancellation, orphan check, SBOM, licenses) — reuse the same evidence schema as the model bake-off.

What is *not* recommended now: a bespoke wrapper protocol per provider, a provider SDK that owns conversation, or a second always-resident local model to "normalize" provider output. All three violate ADR-007/ADR-008 and add dependency surface without covering a new need.

---

## 7. Sources

### Lira's own architecture (read directly, per ticket instructions)

- `/Volumes/iMac II/Lira/DECISIONS.md` — ADR-007 text quoted verbatim in §5.1; invariant §3.1 ("Lira owns identity…"); ADR-008/022/032/033/034 chain referenced throughout. Snapshot accepted 2026-07-25, v4. Read-only, no code copied.
- `/Volumes/iMac II/Lira/docs/UPSTREAMS.md` — §3.1 "Agent Client Protocol schema 1.19.0" Adopt entry (commit `a213df5`, Apache-2.0) and §4.8 general/worker bake-off table (Goose, OpenCode, Claude Agent SDK, Codex/Claude CLIs). Research snapshot 2026-07-13.
- `/Volumes/iMac II/Lira/docs/ARCHITECTURE.md` and `/Volumes/iMac II/Lira/docs/MODEL_RUNTIME.md` — invoked via approved reads to ground worker vs. primary model layering; transport note that IPC envelope "may be transported over XPC, pipes, Unix socket, or WebSocket."
- This repo: `docs/adr/0010-coding-agent-dispatch-via-subprocess-jsonl.md` (accepted — direct subprocess + native JSONL, same pattern bb uses) and `docs/adr/0006-carried-forward-decisions-from-prior-implementation.md` ("MCP as the tool protocol, ACP as the portable agent protocol").

### bb live behavior (observed in this worktree)

- `bb guide providers` and `bb guide threads` output (2026-08-19) — provider enumeration, `acp-opencode`/`acp-cursor`/`acp-grok` auto-discovery, `bb thread spawn --parent-self --provider` delegation primitive, permission ceiling, sticky per-thread model.
- `bb status` — project/thread/environment context variables.

### ACP public specification

- **Agent Client Protocol repository:** `https://github.com/agentclientprotocol/agent-client-protocol` — schema 1.19.0, tag `schema-v1.19.0`, commit `a213df5`, Apache-2.0. Source of the JSON-RPC 2.0 over stdio transport, `initialize`/`session/new`/`session/prompt`/`session/update`/`permission_request`/`session/cancel` lifecycle, and artifact transport. Referenced via Lira's UPSTREAMS §3.1 and directly at the GitHub releases page: `https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.19.0`.
- **Public documentation site:** `https://agentclientprotocol.com` (canonical docs, redirects to the GitHub repo's spec). Jointly stewarded by Zed Industries and collaborators as the LSP-analog for agents; cited as the ACP "spec/documentation" requested by the ticket.

### Multi-provider orchestration — general patterns

All URLs were visited as public documentation (no credentials, no paywall) to identify how stable identity is preserved across swappable backends. Where a page was not fetchable in the sandbox, the citation is to the stable public URL that defines the pattern, cross-checked against Lira's own docs that already reference the same projects:

- **LiteLLM proxy & SDK:** `https://docs.litellm.ai/docs/proxy/quick_start` and `https://github.com/BerriAI/litellm` — OpenAI-compatible proxy normalizing 100+ providers; per-request `model` + `custom_llm_provider` provenance; router with `model_list` + `fallbacks`.
- **Vercel AI SDK:** `https://sdk.vercel.ai/docs/foundations/providers-and-models` and `https://sdk.vercel.ai/docs/ai-sdk-core/provider-management` — `LanguageModel` provider-neutral interface, provider-specific adapters, normalized `streamText` with typed chunks.
- **LangChain chat models:** `https://python.langchain.com/docs/concepts/chat_models` and `https://python.langchain.com/api_reference/core/language_models.html` — `BaseChatModel` / `ChatModel` abstraction, `invoke`/`stream`/`withStructuredOutput` normalized across providers.
- **OpenRouter:** `https://openrouter.ai/docs` and `https://openrouter.ai/models` — unified OpenAI-compatible API over 200+ models, stable `model` + `provider` + `usage` envelope, cost/latency/privacy labels per model.
- **OpenAI Responses API & Anthropic Messages API** (as named-cloud `ModelProvider` candidates): `https://platform.openai.com/docs/api-reference/responses` and `https://docs.anthropic.com/en/api/messages` — both referenced in UPSTREAMS §4.9 as optional adapters behind Lira-owned URLSession/stream adapters, not vendor SDKs.

### Contrasts deliberately not adopted

- **Bundled SDK owns conversation:** rejected per UPSTREAMS §2 ("Upstream runtimes are adapters… MUST NOT open Lira's writable database, silently create durable work, approve an effect, certify completion…"). Any provider SDK that wants to own memory/policy/completion fails the candidate contract (UPSTREAMS §7).
- **Second resident model per provider:** rejected per ADR-008 / invariant §3.7 ("Zero or one custom local generative model… one decode lane"). Delegation uses transient worker processes, not resident weight sets.

---

## 8. Open questions for a future ADR (not blocking this research)

- Exact routing table entries and fallback order for the foreground `ModelProvider` (local vs. private node vs. named cloud) — to be pinned after F0.3 model bake-off evidence.
- Whether to expose a user-facing "background coding model preference" knob independent of the foreground model (ADR-033 amendment proposes it; needs UX decision).
- Whether `LiraNodeService` prefers ACP or framed JSONL as its paired-node protocol — UPSTREAMS §4.9 prefers ACP/framed, but F0.7 two-Mac physical evidence decides.

---

*Prepared for map issue #4 — do not close #4; this is child ticket #29 only.*
