# Research: WebRTC transport options for remote/iPhone access

**Ticket:** wayfinder research #11 (child of map #4)
**Use case:** Lira's remote / iPhone access via a Tailscale-hosted PWA, on a solo-owner, local-first, resource-constrained app (16 GB Mac, native Swift/SwiftUI).
**Question:** SmallWebRTC/Pipecat vs. Pion, plus any other credible option, with tradeoffs for this app profile.

---

## TL;DR

- **First, question the premise.** For a *Tailscale* PWA, WebRTC is usually the wrong default. Tailscale already provides a private encrypted overlay network (WireGuard-based), so WebRTC's entire reason for existing — ICE/STUN/TURN NAT traversal — is largely moot. If the iPhone only needs to **send commands, read state, or get occasional snapshots**, a plain WebSocket (or HTTP + SSE) endpoint on the Mac over the tailnet is dramatically simpler, lighter, and requires no signaling server, no codecs, and no MTU fiddling.
- **WebRTC earns its complexity only when you need low-latency media**: live screen share (sub-second, continuous) or real-time voice into the Mac. Then the real candidates are Pion, LiveKit, and native libwebrtc.
- **SmallWebRTC/Pipecat is the weak fit here.** It's a Python voice-agent framework whose `SmallWebRTCTransport` is built on `aiortc` (Python). It brings a Python runtime and heavy deps (OpenCV for video) to a native Swift app, and its docs even document a data-channel MTU stall specifically on **Tailscale overlays**. Only consider it if Lira's roadmap becomes Python-based voice AI.
- **Pion (Go) is the best "real WebRTC" option for this profile** if media is required: pure Go, no CGO, compiles to a single small static binary, runs as a lean sidecar, huge community, and it's the foundation LiveKit itself is built on.
- **LiveKit is the best "Swift-native" option**: a Go SFU (built on Pion) paired with a mature native Swift client SDK and a browser SDK. Heavier than bare Pion (you run an SFU server), but if you'd rather keep everything in Swift and get a full room/media/screen-share stack out of the box, it's very well supported.

**Recommendation:** Start with **WebSocket-over-Tailscale** for the control surface (no WebRTC). If/when live media is required, adopt **Pion as a sidecar**; choose **LiveKit** if the media stack should be Swift-native instead. Defer SmallWebRTC/Pipecat unless the app becomes a Python voice agent.

---

## Why WebRTC may be unnecessary (the Tailscale insight)

WebRTC exists to connect two endpoints that otherwise couldn't reach each other — through NATs, firewalls, and unknown networks — using ICE with STUN/TURN relays. The entire negotiation (`RTCPeerConnection`, offer/answer, candidate gathering) is scaffolding for that problem.

In a Tailscale deployment, the overlay network (WireGuard) has already solved connectivity: the iPhone and the Mac each have stable, reachable, mutually-encrypted addresses on the tailnet. That collapses the WebRTC value proposition:

- No STUN/TURN needed (the Pipecat docs' own ICE table shows STUN/TURN are needed "as soon as peers are on different networks"; on the tailnet they're on the same virtual network).
- A TCP/WebSocket connection from the browser to `http://<mac-tailnet-ip>:port` is sufficient and much simpler.
- Local-first and resource-constrained both favor skipping a second transport and its state machines entirely.

WebRTC's remaining genuine advantages over WebSocket, for this use case, are limited to:
1. **Low-latency continuous media** — live screen share / real-time audio with jitter buffers and congestion control built in.
2. (Marginal) UDP transport for latency-sensitive data.

If neither is on the roadmap, **do not add WebRTC**. This is the single highest-leverage finding.

---

## Option-by-option

### 1. Pion (Go) — the lean "real WebRTC" choice

- Pure Go implementation of the WebRTC API; **no CGO**, compiles to a single static binary, works across macOS/Linux/Windows/iOS/Android/WASM.
- Implements `PeerConnection`, full ICE, ICE restart, STUN, TURN, data channels (ordered/unordered, reliable/unreliable), and media (Opus, H.264, VP8/9 with packetizers, simulcast, NACK, congestion control).
- **Resource profile:** excellent — a small static sidecar, no interpreter, no native codec framework to ship. Ideal for a 16 GB Mac running a local-first app.
- **Deployment model:** must run as a separate Go process (or be cross-compiled/embedded via cgo, which reintroduces complexity). For a solo owner, a small Go sidecar launched by the Swift app is straightforward.
- **Maturity:** very large community (16.7k stars), used by many projects; notably it's the foundation LiveKit is built on.
- **Tradeoffs:** it's a *library*, not a full stack — you own signaling (a tiny WebSocket or HTTP endpoint for offer/answer is fine over Tailscale) and any media source/sink wiring. No official Swift API (you talk to it as a sidecar via its signaling + your own control protocol).

### 2. LiveKit — the "Swift-native / full stack" choice

- Go SFU ("Selective Forwarding Unit") server built on Pion, self-hostable, Apache-2.0.
- Ships first-class **native Swift SDK** (`livekit/client-sdk-swift`, iOS/macOS/tvOS/visionOS, SwiftPM) **and** a browser SDK (`client-sdk-js`) — meaning both the Mac side and the iPhone PWA have well-supported, maintained client libraries; there's even a SwiftUI components package.
- Handles rooms, multi-party, screen sharing, data messages, E2EE — a lot for free. Signing via JWT access tokens (minted by the Mac).
- **Resource profile:** heavier than bare Pion — you run a LiveKit *server* (itself on Pion) plus a Swift client. Overkill for a single-user, single-room Tailscale setup, but still lightweight in absolute terms for one room.
- **Tradeoffs:** you add an SFU hop and a server process; media routes Mac → SFU → iPhone (or P2P within the room). For a strictly 1:1 local case the SFU adds nothing functionally. Best justification: if Lira wants the **media stack in Swift** and room/recording/forwarding features later, LiveKit is the most supported path and its Swift client is far easier than driving libwebrtc directly.

### 3. SmallWebRTC / Pipecat — the voice-agent option (weak fit)

- **Pipecat** is an open-source **Python** framework for real-time voice/multimodal agents.
- **SmallWebRTCTransport** is Pipecat's serverless P2P WebRTC transport; it implements audio/video/data channels "no provider needed."
- **Underlying stack:** the `webrtc` extra provides audio/basic video **via `aiortc`** (a Python library wrapping the native libwebrtc stack); video adds OpenCV.
- **Directly relevant gotcha (citable):** Pipecat's docs document that `aiortc` data channels can **silently stall over Tailscale/VPN overlays** due to SCTP chunk-size vs. MTU (`EMSGSIZE` drops), and recommend capping `PIPECAT_SCTP_MAX_CHUNK_SIZE` at 1100 bytes. So even within its own ecosystem, Tailscale + aiortc needs manual tuning. (Note: this MTU/SCTP principle applies to *any* WebRTC data channel over Tailscale — worth remembering regardless of stack.)
- **Fit assessment for Lira:** poor for a native Swift app. It assumes a Python `bot()` process, brings a Python runtime + OpenCV + aiortc, and is oriented at voice-AI pipelines. It would only make sense if Lira's remote-access story becomes "the Mac runs a Python voice agent that the PWA talks to" — a fundamentally different, heavier architecture than Lira's current native Swift shape.
- It also requires an HTTPS origin for browser media (browser blocks mic/cam on insecure origins) — over a LAN Tailscale IP that means dealing with certs for a local origin, another friction point WebSocket-with-auth avoids.

### 4. Native libwebrtc (Google, e.g. the `webrtc-sdk` fork LiveKit wraps) — the "in-process Swift" option

- The true native path: compile/bundle libwebrtc as an XCFramework and drive `RTCPeerConnection` from Swift in-process. LiveKit's `LiveKitWebRTC.xcframework` is exactly this.
- **Resource profile:** worst of the real options — a large compiled framework, heavy build tooling, complex C/ObjC API, and it bloats the binary. App Store dSYM warnings are a known annoyance.
- Only worth it if you specifically need in-process WebRTC with no sidecar and are willing to own the complexity. For a solo owner, the LiveKit Swift SDK on top of it is the sane way to touch this stack.

---

## Decision matrix (for Lira's profile)

| Need | Recommendation | Why |
|---|---|---|
| Commands / state / snapshots over Tailscale | **WebSocket + HTTP over tailnet (no WebRTC)** | Simplest, lowest memory, no signaling/codecs; Tailscale already provides connectivity |
| Live screen share / real-time voice (media required) | **Pion sidecar (Go)** | Pure-Go single static binary, tiny footprint, full data-channel + media support; you own signaling (trivial over tailnet) |
| Media stack kept **in Swift**, room/forwarding later | **LiveKit** (Go SFU + Swift + browser SDKs) | Mature native Swift + browser clients, full room/screen-share/E2EE stack; heaver than bare Pion |
| Voice-AI Python agent as the product | **SmallWebRTC/Pipecat** | Only justified if Lira itself becomes a Python voice agent; heavy deps, Tailscale MTU gotcha, HTTPS-origin requirement |

## Recommended decision (a "Decisions so far" gist)

> WebRTC only if live media is required; default is WebSocket-over-Tailscale for the control surface. If media, use Pion sidecar (leanest) or LiveKit (Swift-native); avoid SmallWebRTC/Pipecat unless the app becomes a Python voice agent. Cap WebRTC data-channel chunk size ~1100 B over Tailscale.

## Open questions for the map (#4)

- Does remote/iPhone access require **live** screen sharing / voice, or is on-demand snapshot + control enough? (This single answer decides whether WebRTC is needed at all.)
- Is Lira's remote surface Swift-native (favors LiveKit) or sidecar-tolerant (favors Pion)?
- Is HTTPS/cert handling for the Tailscale origin acceptable for the PWA?

## Sources

- Pion WebRTC (pure-Go, no CGO, features, single binary, WASM support): https://github.com/pion/webrtc
- Pion is the foundation of LiveKit (LiveKit server built on Pion): https://github.com/livekit/server-sdk-go
- LiveKit Swift client SDK (iOS/macOS, SwiftPM, screen share, E2EE, thread-safety notes): https://github.com/livekit/client-sdk-swift
- LiveKit browser SDK (PWA client): https://github.com/livekit/client-sdk-js
- Pipecat (Python realtime voice-agent framework, transports incl. SmallWebRTC): https://github.com/pipecat-ai/pipecat
- SmallWebRTCTransport docs (aiortc-backed; ICE/STUN/TURN table; **Tailscale SCTP MTU stall + `PIPECAT_SCTP_MAX_CHUNK_SIZE=1100`**; HTTPS-origin requirement): https://docs.pipecat.ai/api-reference/server/services/transport/small-webrtc
