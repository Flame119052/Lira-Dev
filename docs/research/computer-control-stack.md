---
title: Research — computer-control stack (Cua vs. Apple accessibility API)
status: research
date: 2026-08-18
ticket: "#9"
parent-map: "#4"
---

# Computer-control stack: Cua vs. a direct Apple accessibility-API stack

Research for the screen/computer-control subsystem. The scope was already fixed by
[ADR-0006](adr/0006-carried-forward-decisions-from-prior-implementation.md): **per-app-scoped and
visible** control — capture and act within one target app's window, shown via a preview — *not*
whole-screen takeover and *not* invisible background automation (reconfirmed 2026-08-17 against the
owner's "Codex Computer Use, let me keep working otherwise" goal). This ticket only weighs the two
candidate implementation stacks beneath that fixed scope.

## Candidate 1 — Cua (trycua/cua)

[Cua](https://github.com/trycua/cua) describes itself as "Scale computer-use 2.0 with open-source
drivers, cross-OS fleets, and benchmarks." It is a large, fast-moving project (21.5k stars, ~4,400
commits, release-please automation). Its relevant piece for Lira is **Cua Driver**, a background
computer-use daemon that "drives native macOS apps without stealing focus." [^cua-readme] [^driver-readme]

Integration shape:

- **Language/transport:** The macOS driver is a **Rust** daemon exposing **MCP over stdio**, with
  generated Python/TypeScript SDK bindings via UniFFI over a versioned C ABI. There is no native
  Swift API; a Swift app would talk to it either as an MCP client or by embedding the native Rust
  runtime. [^driver-readme]
- **Permissions:** On macOS it needs the same **Accessibility and Screen Recording** TCC grants as a
  direct accessibility stack, and those grants attach to an app identity — Cua's own docs walk through
  standalone `CuaDriver.app`, direct MCP, and "embedded host" launch modes to get attribution right.
  [^driver-readme]
- **Capability model:** Permission modes (`standard` / `bounded` / `unrestricted`), a capability
  manifest, window-scoped `screenshot` tooling, action history. [^driver-readme]

License and dependencies:

- Core repo is **MIT**. Caveats: the optional `cua-agent[omni]` extra pulls in **ultralytics (AGPL-3.0)**
  and **OmniParser (CC-BY-4.0)**. The repository itself explicitly flags this. [^cua-readme]
- Minimum **macOS 14.0** (matching Lira's own practical floor). [^ocu-readme notes Cua/macOS 14]

Fit with Lira's fixed scope — the central tension:

- Cua Driver's entire pitch is **background, non-focus-stealing automation** — the exact inverse of
  Lira's "visible, shown via preview" requirement. Lira would have to build its own visibility/preview
  layer on top anyway, while Cua actively optimizes *away* from visibility.
- Under the hood, Cua's macOS driver **already depends on Apple's accessibility APIs** (it needs the
  same TCC grants and reads the same accessibility tree). It does not remove the accessibility-API
  dependency; it wraps it in Rust and adds an MCP process boundary.
- Cua's headline differentiators — cross-OS fleets, sandboxes/VMs (Lume), cloud (cua.ai), benchmarks
  for training — are largely irrelevant to a **local-first, single-Mac, native Swift** app.
- Cost of adoption: a security-critical Rust daemon with full desktop control running as an external
  process, a fast-moving third-party surface to track and version-pin, and (for the agent-loop
  behavior) an orientation toward hosted/cloud models that conflicts with Lira's one-resident-local-model
  constraint.

## Candidate 2 — Direct Apple accessibility APIs in Swift

Build the control primitive directly on Apple's public, shipped accessibility surface. The pieces:

- **`AXUIElement` (ApplicationServices / Accessibility framework)** — read another app's accessibility
  tree (`AXUIElementCopyAttributeValue`, multiple-attribute variants), perform actions
  (`AXUIElementPerformAction`, e.g. `kAXPressAction`), set values, observe via `AXObserver`.
  [^axuielement]
- **`AXIsProcessTrusted`** — the trust check backing the **Accessibility** TCC grant; the app prompts
  in System Settings once, exactly as the owner expects of a first-party-feeling control plane.
- **`ScreenCaptureKit`** (`SCShareableContent` / `SCWindow`) — per-window capture for the live preview,
  backed by the **Screen Recording** TCC grant. This is the natural way to satisfy "captures within one
  target app's window, shown via a preview."
- **`CGEventPost`** — synthesizing mouse/keyboard input for the acting side, gated by the same
  Accessibility trust.

Concrete proof it works at this exact scope: **`open-codex-computer-use`** is an **MIT, native Swift**
("OpenComputerUseKit") implementation of non-intrusive, per-app-scoped computer use built directly on
accessibility, distributed as an MCP server, explicitly inspired by OpenAI's Codex Computer Use.
[^ocu-readme] [^ocu-kit] It is strong evidence that option 2 is not speculative — a working, scoped
reference exists.

Tradeoffs:

- **Reliability depends on the target app exposing a usable accessibility tree.** Well-behaved native
  and standard toolkits do; apps with custom-drawn or embedded-web UI (some Electron/apps, games, exotic
  widgets) can expose a thin or missing tree. This is a per-app robustness concern, not a stack blocker,
  and is shared with Cua (same tree underneath). Mitigations: element-based actions where available,
  coordinate fallback for stubborn targets, and per-app capability notes.
- **Everything must be built in-house** — tree walking, action mapping, input synthesis, preview wiring.
  More first-build effort than dropping in a dependency, but each piece is small, well-documented, and
  directly under Lira's deterministic-policy control (ADR-0006's "deterministic policy as authority").
- **No license/attribution overhead** — purely Apple public APIs + the OS.
- **Maintenance burden is low and owned**: no third-party upgrade treadmill, no version-pinning of a
  moving dependency; maintenance tracks macOS SDK changes, which arrive annually and are surfaced by the
  toolchain.

## Comparison

| Axis | Cua (Cua Driver) | Direct Apple AX stack |
| --- | --- | --- |
| Capabilities | Background desktop control, window-scoped screenshots, MCP surface, cross-OS | Per-window capture + element/action control + input, exactly scoped, native Swift |
| Fit with Lira scope | **Poor** — pitches invisible/non-focus-stealing background automation, opposite of visible+preview | **Exact** — window-scoped, visible, per-app |
| Reliability | Depends on same accessibility tree (Rust wrapper) | Depends on same accessibility tree (direct) |
| Licensing | MIT core; **AGPL-3.0/CC-BY-4.0 caveats** on optional omni deps | None — Apple public APIs |
| Maintenance | Fast-moving third party (4.4k commits); pin + track; security-critical daemon | Owned; tracks annual macOS SDK; no external dep |
| Integration | Rust daemon over MCP or embedded C ABI; no native Swift API | Native Swift, in-process |
| Runtime footprint | External process (Rust) + MCP boundary | In-process, minimal |

## Recommendation

Build **directly on Apple's public accessibility APIs in Swift** (candidate 2), following the shape
proven by `open-codex-computer-use`: `AXUIElement` for tree/actions, `AXIsProcessTrusted`/TCC for the
Accessibility grant, `ScreenCaptureKit` for the per-window preview, `CGEventPost` for input. Reasons:

1. It matches the **fixed scope exactly** (per-app, visible, preview) instead of fighting Cua's
   background-automation orientation.
2. It keeps Lira **native Swift, minimal-footprint, and single-process** per ADR-0003 and the strict
   16 GB RAM budget — no embedded Rust runtime or MCP subprocess.
3. It places the control primitive **directly under Lira's deterministic-policy authority**, rather than
   inside a third-party daemon, aligning with ADR-0006's security model and the authenticated-XPC /
   no-open-control-plane rule.
4. **Licensing and maintenance are clean**: no AGPL/CC-BY exposure, no upgrade treadmill.
5. A working **MIT, native-Swift reference implementation exists** at this exact scope, de-risking the
   build.

Cua remains a reasonable reference for *behavior patterns* (permission modes, capability manifests,
window-scoped capture) worth borrowing into Lira's own design, and a fallback if a later milestone
needs cross-OS — but it is not the right stack for Lira's local-first, single-Mac, visible control.

## Sources

[^cua-readme]: Cua README & license — https://github.com/trycua/cua (MIT; AGPL-3.0/CC-BY-4.0 flagged on optional `cua-agent[omni]` deps).
[^driver-readme]: Cua Driver README — https://github.com/trycua/cua/blob/main/libs/cua-driver/README.md (Rust daemon, MCP over stdio, UniFFI SDKs, macOS TCC attribution, permission modes, "without stealing focus").
[^axuielement]: Apple — AXUIElement (ApplicationServices/Accessibility) — https://developer.apple.com/documentation/applicationservices/axuielement
[^ocu-readme]: open-codex-computer-use README — https://github.com/iFurySt/open-codex-computer-use (MIT; non-intrusive CUA on Accessibility; macOS 14+, Accessibility + Screen Recording grants).
[^ocu-kit]: OpenComputerUseKit (Swift package) — https://github.com/iFurySt/open-codex-computer-use/tree/main/packages/OpenComputerUseKit
