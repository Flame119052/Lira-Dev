---
status: accepted
---

# Native Swift/SwiftUI + AppKit app plane retained

Reconsidered cross-platform alternatives (Electron, Tauri) against native Swift/SwiftUI, since AI coding agents are generally more reliable writing mainstream web-stack code (JS/TS/React) than SwiftUI, and unreliable agent-written code was a named cause of the prior attempt's failure.

Decision: stay native (Swift/SwiftUI + AppKit). Lira's actual non-negotiables — accessibility-tree computer control, real-time voice barge-in, one resident local model sharing a strict 16GB RAM budget, true menu-bar presence — depend on deep OS integration and a minimal runtime footprint. Electron's Chromium overhead is incompatible with the RAM budget; Tauri narrows that gap but still needs native bridges for accessibility and menu-bar behavior, so the main benefit of going cross-platform (more reliable agent-generated UI code) doesn't fully materialize once those bridges are still required.

Open item, not resolved by this ADR: the owner's actual concern was whether the UI can *look* more polished, which is a UI/visual-design question, not a framework choice — revisit during actual UI design work, don't treat SwiftUI's retention as having settled it.
