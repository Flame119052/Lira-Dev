# Research: per-app / per-context permission granularity models

Ticket: [wayfinder:research #21](https://github.com/Flame119052/Lira-Dev/issues/21) (child of map [issue #4](https://github.com/Flame119052/Lira-Dev/issues/4)).

Lira is a personal AI assistant that can take actions on the owner's Mac. Before we decide how much the owner must configure, we need the facts on how comparable systems actually model fine-grained permission/trust — what granularity levels are really used in practice, and what each costs a non-technical user. This doc surveys five families of systems: mobile OS permissions (iOS/Android), macOS sandboxing + TCC, per-app firewalls (Little Snitch, LuLu, the built-in firewall), browser extensions, and AI agent tool-permission frameworks. Primary sources throughout.

---

## The core finding up front

Across every family, the same three granularity levels recur, and a clear pattern emerges about which one real products ship:

1. **Named rules** — a permission targets a specific named thing (a specific app, a specific app→endpoint pair, a specific command/domain). Maximum precision; maximum maintenance burden.
2. **Category buckets** — a permission targets a class of things (Camera, Mic, Location; "read files" vs "edit files" vs "run commands"). Coarse but cheap to understand and maintain.
3. **Dynamic / inferred** — the system decides at runtime whether to act or ask, based on a model/classifier or on context. Low configuration burden, but not a hard security boundary.

**What actually ships:** consumer-facing systems overwhelmingly use **category buckets + a remembered "never ask again" escape hatch**, prompted in context at the moment of first use, with a settings page for later changes. Fine-grained *named* rules exist (Little Snitch, Claude Code, opencode) but are the domain of technical users or are **auto-learned from a one-time approval** rather than hand-authored. Pure dynamic/inferred classification is increasingly common but is explicitly *not* treated as a security boundary — it sits on top of a deterministic deny layer.

The practical implication for Lira's non-technical owner: **a good design does not ask the owner to author permission rules.** It prompts once, in context, in plain-language buckets, remembers the answer, and offers a settings page.

---

## 1. Mobile OS per-app permission systems (iOS / Android)

### Granularity in practice

- **iOS is coarse: per-app × per-resource, all-or-nothing for that resource.** Each protected resource (Camera, Mic, Location, Contacts, Photos…) has its own `Info.plist` usage-description key, and access is granted per-app per-resource ([Requesting access to protected resources](https://developer.apple.com/documentation/UIKit/requesting-access-to-protected-resources), [Protecting the user's privacy](https://developer.apple.com/documentation/uikit/protecting-the-user-s-privacy)). There is no generic permission enum — it is one toggle per category.
- **Android is finer: many named permissions**, but **permission groups exist purely to reduce the dialog count** (several related permissions show in one dialog) and apps are explicitly told not to rely on the grouping ([Permissions overview](https://developer.android.com/guide/topics/permissions/overview), [Requesting permissions](https://developer.android.com/guide/topics/permissions/requesting-permissions)).
- **Both add a small number of special scopes beyond the bucket:**
  - iOS location: **While-Using vs Always**, plus **Allow Once** (single session) and approximate-vs-precise ([Requesting authorization to use location services](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services), [Protected resources](https://developer.apple.com/documentation/bundleresources/protected-resources), [CLAccuracyAuthorization](https://developer.apple.com/documentation/corelocation/claccuracyauthorization)).
  - iOS photos: **"Limited" / "Select Photos"** subset access, and a permission-free out-of-process picker (`PHPickerViewController`) ([Enhanced privacy in Photos](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)).
  - Android: **one-time** location/mic/camera ("Only this time"), **approximate vs precise** location (Android 12+), and **scoped media** permissions + a permission-free photo picker (Android 13+) ([Android 13 behavior changes](https://developer.android.com/about/versions/13/behavior-changes-13), [Android 12 behavior changes](https://developer.android.com/about/versions/12/behavior-changes-12)).

### Usability tradeoffs

- **The core cost is a context switch on each protected resource.** Both platforms push developers to request **in context, at the moment of need** (never at launch) because that is when users grant — and to explain the *why* in the prompt text ([Apple](https://developer.apple.com/documentation/uikit/protecting-the-user-s-privacy), [Android](https://developer.android.com/guide/topics/permissions/overview)).
- **The decision is remembered, not repeated.** iOS: "the system remembers the person's choice and doesn't prompt again"; denial sticks until a full reset or `tccutil reset` ([Requesting access](https://developer.apple.com/documentation/UIKit/requesting-access-to-protected-resources)). Android adds a hard stop: denying twice sets a permanent "don't ask again" flag, and apps are told not to nag ([Requesting permissions](https://developer.android.com/guide/topics/permissions/requesting-permissions)).
- **Both route later changes to a central settings page** (iOS Privacy menu; Android per-app settings), and apps must gracefully degrade when a permission is missing.
- **Friction-reduction is the shared playbook: prompt once, in context, with an explanation, remember the answer, expose settings.** Android adds an explicit anti-nag hard stop; iOS relies on never re-prompting until reset.

**Level used:** category buckets (+ a few special scopes). **Cost to a non-technical user:** low, *because the platform remembers* — the user makes each category decision once.

---

## 2. macOS sandboxing, entitlements, and TCC

macOS has **two complementary layers**, which is directly relevant to Lira's design:

1. **Entitlements (build-time, developer-declared, baked into the code signature).** These are largely **coarse per-capability booleans** — the App Sandbox master switch plus capability toggles like `com.apple.security.network.client/server`, `files.user-selected.read-only/read-write`, `device.camera/microphone`, `personal-information.contacts/location/calendars` ([Security entitlements](https://developer.apple.com/documentation/bundleresources/security-entitlements), [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)). No user prompt — these say what the app *may* touch.
2. **TCC (runtime, user-consented, per-app × per-resource).** "The system asks the user for permission on behalf of your app" per protected resource, per app ([Protected resources](https://developer.apple.com/documentation/bundleresources/protected-resources)). Each resource has its own `UsageDescription` string; **a missing string causes the app to be terminated** ([Requesting authorization for media capture on macOS](https://developer.apple.com/documentation/BundleResources/requesting-authorization-for-media-capture-on-macos)). TCC covers ~40 gateable resources (Camera, Mic, Accessibility, Screen Recording, Contacts, Full Disk Access, …) ([Resetting access to protected resources](https://developer.apple.com/documentation/Xcode/resetting-access-to-protected-resources-in-macOS)).

**Usability:** prompts appear only the **first time** the app touches a resource; "macOS remembers the user's response" ([Requesting authorization for media capture](https://developer.apple.com/documentation/BundleResources/requesting-authorization-for-media-capture-on-macos)). Decisions are revocable in System Settings / Privacy, or reset programmatically via `tccutil reset`. Apple's only real friction lever is a good one-sentence purpose string, and prompting only when the feature is actually invoked.

**Level used:** category buckets (per-resource), all-or-nothing per app. **Cost to a non-technical user:** low — one remembered decision per resource.

---

## 3. Firewall tools with per-app rules (Little Snitch, LuLu, built-in)

This is the family where the granularity is **finest and most named** — and where the usability cost is highest, which is why the products add so much friction-reduction.

- **Little Snitch is per-connection, not just per-app.** Every unmatched connection raises an alert; you allow/deny that specific app→server/domain/port/protocol pair before data flows, and the decision creates a persistent rule ([obdev.at product page](https://www.obdev.at/products/littlesnitch/index.html)). Rules can be identified by **cryptographic code signature** so they survive app moves/renames, and are organized with **rule groups, profiles (with automatic switching per network), and curated blocklists** — the category-bucket escape hatch.
- **The known burden is prompt fatigue**, and the product answers it with exactly the standard mechanisms: **Silent Mode** (auto-allow new connections now, decide later), a **Network Monitor** (observe and retroactively create rules), profiles, blocklists, and **assisted maintenance** (it flags redundant/invalid rules and suggests new ones) ([obdev.at](https://www.obdev.at/products/littlesnitch/index.html)).
- **LuLu (free, open-source)** documents the same lifecycle precisely: each alert names the process and destination, and the decision has a **scope** (whole process vs specific endpoint) and a **duration** (always / process-lifetime / until a future time), plus allow/block *lists* and profiles ([LuLu](https://objective-see.com/products/lulu.html)).
- **The macOS built-in firewall is much coarser**: per-app allow/block for **incoming** connections only — no outgoing filtering, no port/protocol/endpoint granularity ([Apple Support — firewall](https://support.apple.com/en-in/guide/mac-help/mh34041/26/mac/26), [Firewall settings](https://support.apple.com/en-in/guide/mac-help/mh11783/26/mac/26)).

**Level used:** named app→endpoint rules (fine), organized into buckets/profiles/blocklists, with dynamic-style modes (Silent/Monitor) layered on top. **Cost to a non-technical user:** **the highest of any family** — per-connection decision-making. The products only become usable because of modes that defer the decisions.

---

## 4. Browser extension permission models

Browser extensions are the family that has thought hardest about *install-time vs runtime* and *just-in-time, per-context* grants — the most relevant ideas for Lira.

- **Tri-axial granularity: what (API permission, e.g. `tabs`, `storage`, `clipboardWrite`), where (host permission via match patterns like a specific site vs `<all_urls>`), and when (install-time `permissions` vs runtime `optional_permissions`)** ([MDN permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions), [Chrome declare-permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions)).
- **Manifest V3 pushes "minimized permissions":** host permissions are a separate key, optional permissions are encouraged ("provide users with informed control over access to resources and data"), and warning-triggering permissions are surfaced at install and re-gated on update (an extension adding a warning permission is **disabled until the user re-accepts**) ([What is MV3](https://developer.chrome.com/docs/extensions/develop/migrate/what-is-mv3), [declare-permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions), [permission-warnings](https://developer.chrome.com/docs/extensions/develop/concepts/permission-warnings)).
- **The "no scary warnings" trend and its trade-off:** the flagship case is `activeTab`, marketed as a **warning-free alternative to `<all_urls>`** — but it only lets the extension act on the current tab, in response to a user action. The intrinsic tension: **power breadth correlates with warning surface** ([activeTab](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab), [permission-warnings](https://developer.chrome.com/docs/extensions/develop/concepts/permission-warnings)).
- **Install-time warnings are widely ignored**, so browsers add post-install management: Safari's per-site **Ask / Allow for single use / Allow for the day / Allow for all websites / Deny** ([Apple — managing permissions](https://developer.apple.com/documentation/safariservices/managing-safari-web-extension-permissions)), Firefox host-permission grants/revocations from the Add-ons Manager, and Chrome's per-extension permission management.
- **`activeTab` is the closest existing primitive to a *just-in-time, per-context grant*:** scoped to one tab, gated on an explicit user gesture, and **auto-revoked on navigation or tab close** — limiting the blast radius if the extension is compromised ([MDN activeTab](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions#activetab_permission), [Chrome activeTab](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab)).

**Level used:** category buckets (API permission + host scope) with a just-in-time, per-context `activeTab` grant and runtime optional grants. **Cost to a non-technical user:** low at the point of use (runtime, contextual requests), though install-time warnings are blunt.

---

## 5. AI agent tool/action permission frameworks

This family is the closest to Lira's own situation. The picture is consistent:

### Claude Code — the richest, tiered rule + mode model
- **Three rule outcomes — `allow`, `ask`, `deny` — evaluated in fixed order deny → ask → allow.** Rules target a tool or a tool+specific value: `Bash`, `Bash(npm run build)`, `Read(./.env)`, `WebFetch(domain:example.com)`, globs, MCP and subagent rules ([Claude Code — Configure permissions](https://code.claude.com/docs/en/permissions)).
- **Default prompting is per tool type** (category buckets): read-only file tools and a built-in list of read-only Bash commands run unprompted; Bash, edits, and WebFetch generally prompt.
- **The "Yes, and don't ask again" button auto-writes a persistent rule** to `.claude/settings.local.json` — i.e. **fine-grained rules are learned from one-time approvals, not authored up front**.
- **Permission modes** (`default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`) shift how much prompting happens. **`auto` uses a safety classifier instead of prompting** — convenient, but an LLM judgement, not a boundary. **`bypassPermissions`** skips prompts (except protected actions) and is explicitly warned for isolated environments only.
- **Crucially:** "Permission rules are enforced by Claude Code, not by the model" — the harness, not the model's instructions, is the boundary. Static deny rules + sandboxing are the layer that survives prompt injection.

### LangChain / LangGraph — a mechanism, not a policy
- No declarative per-tool permission config. Instead a **runtime `interrupt()` primitive** pauses graph execution, persists state, and resumes via `Command(resume=...)`. Documented patterns include **approve/reject** and **interrupt inside a tool** (a `@tool` gates its own execution) ([LangGraph — Interrupts](https://docs.langchain.com/oss/python/langgraph/human-in-the-loop)). You write the approval policy yourself.

### AutoGPT-style / plain OpenAI function calling
- **No runtime permission gating in the platform docs.** AutoGPT's modern platform is a block-based workflow you author at design time, then runs autonomously; governance is economic (credits) and credential-based, not allow/deny prompts ([AutoGPT platform](https://agpt.co/docs/platform/what-is-autogpt-platform.md)). Plain function calling is just a request/response contract — "the caller executes it"; gating is entirely the developer's responsibility.

### OpenAI Agents SDK / Computer Use
- The SDK **does have an approval model**: mark a tool `needs_approval=True` or pass a per-call **callable decision**; triggered approvals pause execution and surface `ToolApprovalItem`s you approve/reject and resume; decisions can be cached (`always_approve`) and serialized for durable, long-running approval across processes ([OpenAI Agents SDK — Human-in-the-loop](https://openai.github.io/openai-agents-python/human_in_the_loop/)).
- **Computer use** (driving a GUI, closest to Lira) has **no built-in confirmation model.** OpenAI's own guidance is explicit: "Run Computer use in an isolated browser or VM, **keep a human in the loop for high-impact actions**," and "**only direct instructions from the user count as permission**." Whether to pause and ask before any given click/type action is entirely your harness's job ([OpenAI — Computer use](https://developers.openai.com/api/docs/guides/tools-computer-use)).

### Configurable allow/deny/ask lists (opencode, Cline)
- **opencode** maps each tool to `allow`/`ask`/`deny` with per-tool overrides and granular object syntax (`"bash": { "*": "ask", "git *": "allow", "rm *": "deny" }`), last-matching rule wins, permissive defaults, and an ask prompt offering **once / always / reject** where `always` learns a suggested pattern ([opencode permissions](https://opencode.ai/docs/permissions)).
- **Cline** is the clearest example of **category buckets for non-technical users**: UI toggles for "read files / edit files / safe commands / all commands / browser / MCP". It does **not** use a fixed allowlist — "the model marks each command with a `requires_approval` flag" based on command + args. A **YOLO mode** auto-approves everything and is explicitly flagged dangerous ([Cline auto-approve](https://docs.cline.bot/features/auto-approve.md)).

### Usability tradeoffs (synthesized)

- **Confirm-every-action:** maximum control, but **prompt fatigue / habituation** — users start blindly approving, which defeats the safety; it also breaks autonomous/background flows. OpenAI recommends HITL only for *high-impact* actions, precisely because confirming every screenshot action of a GUI agent is unusable.
- **Autonomous with guardrails:** no friction, enables unattended work — but only as safe as its (a) **static/deterministic** boundaries (deny rules, sandboxing — enforced by the harness, not the model) and (b) **model-based/classifier** gating (convenient, but bypassable, an LLM judgement). A non-technical user's trust must rest on (a).
- **Configured allowlists:** low ongoing friction once set, reusable, predictable — but **fragile with free-form input** (Claude Code's own docs warn prefix allowlists are easy to bypass), and hard for a non-technical user to author. The realistic answer is to **auto-learn the allowlist from one-time approvals**.

**Level used in practice:** category buckets are the dominant consumer-facing granularity; named-command/prefix rules are the fine level but mostly **auto-learned from approvals** or used as deny guards; dynamic/model-inferred classification is the pragmatic default but explicitly not a security boundary; HITL is the engineering mechanism underneath.

---

## Synthesis for Lira

| Family | Granularity level used | Real cost to a non-technical user |
|---|---|---|
| iOS / Android | Category buckets + a few special scopes (temporal, subset, one-time) | Low — platform **remembers** the decision; prompt once in context |
| macOS TCC + entitlements | Category buckets (per-resource), coarse capability toggles | Low — one remembered decision per resource |
| Little Snitch / LuLu | **Named app→endpoint rules** (finest), organized into buckets/profiles/blocklists | **High** — per-connection decisions; only usable with Silent/Monitor modes |
| Browser extensions | API + host buckets; `activeTab` just-in-time per-context grant; runtime optional | Low at point of use; install warnings blunt |
| AI agent frameworks | Category buckets + auto-learned allow/deny/ask rules + dynamic classifier + HITL | Low if designed to prompt in buckets and remember; high if the user must author rules |

**Design guidance for Lira (for a non-technical owner):**
1. **Default to category buckets, not named rules.** People reason about "reads vs edits vs commands" and "Camera/Mic/Screen" — not individual actions. Prompt in plain language at the moment of first use, in context, like iOS/Android/TCC and Cline do.
2. **Remember the answer and offer a settings page.** Every usable system does this. The remembered choices should persist per-category (and per-named command where useful), not just per-session, or the owner re-confirms every run (Claude Code's `settings.local.json`, opencode's `always`, iOS remembered decisions).
3. **Provide a just-in-time, per-context grant for high-stakes/OS actions** — the browser `activeTab` pattern (scoped to the current context, gated on an explicit owner gesture, auto-revoked) and OpenAI's computer-use guidance ("keep a human in the loop for high-impact actions; only direct instructions count as permission").
4. **Put hard, deterministic boundaries underneath any convenience.** Static deny rules on destructive actions (e.g. `rm -rf`) + OS-level sandbox/file access, enforced by the harness, not the model — because dynamic/model-inferred gating is convenient but bypassable (Claude Code's "enforced by Claude Code, not by the model").
5. **Escape hatch to full autonomy must be explicit, reversible, and never the default** (Claude Code `bypassPermissions`, Cline YOLO — both flagged dangerous).
6. **The granularity choice that matters is not "named vs bucket" but "who authors it."** Fine-grained named rules are fine *if the system learns them from one-time approvals*; they are a burden if the owner must write them.

---

## References

**Mobile OS**
- [iOS — Requesting access to protected resources](https://developer.apple.com/documentation/UIKit/requesting-access-to-protected-resources)
- [iOS — Protecting the user's privacy](https://developer.apple.com/documentation/uikit/protecting-the-user-s-privacy)
- [iOS — Requesting authorization to use location services](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services)
- [iOS — CLAccuracyAuthorization](https://developer.apple.com/documentation/corelocation/claccuracyauthorization)
- [iOS — Enhanced privacy in Photos](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)
- [Android — Permissions overview](https://developer.android.com/guide/topics/permissions/overview)
- [Android — Requesting permissions](https://developer.android.com/guide/topics/permissions/requesting-permissions)
- [Android 12 behavior changes](https://developer.android.com/about/versions/12/behavior-changes-12)
- [Android 13 behavior changes](https://developer.android.com/about/versions/13/behavior-changes-13)

**macOS sandbox / TCC**
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)
- [Security entitlements](https://developer.apple.com/documentation/bundleresources/security-entitlements)
- [Protected resources](https://developer.apple.com/documentation/bundleresources/protected-resources)
- [Requesting authorization for media capture on macOS](https://developer.apple.com/documentation/BundleResources/requesting-authorization-for-media-capture-on-macos)
- [Resetting access to protected resources in macOS](https://developer.apple.com/documentation/Xcode/resetting-access-to-protected-resources-in-macOS)

**Firewalls**
- [Little Snitch — product page](https://www.obdev.at/products/littlesnitch/index.html)
- [LuLu (Objective-See)](https://objective-see.com/products/lulu.html)
- [Apple Support — Block connections to your Mac with a firewall](https://support.apple.com/en-in/guide/mac-help/mh34041/26/mac/26)
- [Apple Support — Change Firewall settings on Mac](https://support.apple.com/en-in/guide/mac-help/mh11783/26/mac/26)

**Browser extensions**
- [MDN — manifest permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/permissions)
- [MDN — manifest host_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/host_permissions)
- [MDN — manifest optional_permissions](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/optional_permissions)
- [Chrome — Declare permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions)
- [Chrome — The activeTab permission](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab)
- [Chrome — Permission warning guidelines](https://developer.chrome.com/docs/extensions/develop/concepts/permission-warnings)
- [Chrome — What is Manifest V3](https://developer.chrome.com/docs/extensions/develop/migrate/what-is-mv3)
- [Apple — Managing Safari web extension permissions](https://developer.apple.com/documentation/safariservices/managing-safari-web-extension-permissions)

**AI agent frameworks**
- [Anthropic — Claude Code: Configure permissions](https://code.claude.com/docs/en/permissions)
- [LangGraph — Human-in-the-loop / Interrupts](https://docs.langchain.com/oss/python/langgraph/human-in-the-loop)
- [AutoGPT platform](https://agpt.co/docs/platform/what-is-autogpt-platform.md)
- [OpenAI Agents SDK — Human-in-the-loop](https://openai.github.io/openai-agents-python/human_in_the_loop/)
- [OpenAI — Computer use guide](https://developers.openai.com/api/docs/guides/tools-computer-use)
- [opencode — Permissions](https://opencode.ai/docs/permissions)
- [Cline — Auto-approve](https://docs.cline.bot/features/auto-approve.md)
