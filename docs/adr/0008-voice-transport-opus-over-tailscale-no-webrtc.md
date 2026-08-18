---
status: accepted
---

# Voice transport: raw Opus over the Tailscale tailnet, no WebRTC

Reconsidered after the owner flagged overengineering risk in the first WebRTC-based proposal (LiveKit self-hosted vs. Pion direct). Both options bring WebRTC's NAT-traversal machinery (ICE/STUN/TURN) and, in LiveKit's case, a full SFU server — solving a problem Lira doesn't have, since Tailscale already gives the Mac and iPhone a direct, encrypted, NAT-traversed connection regardless of physical location.

**Decision:** skip WebRTC entirely for v1's voice transport. Capture/playback via native `AVAudioEngine` on both ends; compress with `swift-opus` (a real, maintained Swift Package Manager binding to Opus, proven running multiple 48kHz channels over a live 4G connection in a shipped app); send Opus frames directly over UDP to the peer's Tailscale (100.x.x.x) address. No signaling server, no ICE negotiation, no SFU, no WebRTC dependency tree.

**Why over LiveKit/Pion:** genuinely less to go wrong, not just less infrastructure. Every removed dependency (SFU process, ICE/STUN/TURN stack, WebRTC's much larger surface area) is removed attack surface, removed resource footprint, and removed opportunity for the kind of unreviewable complexity that caused problems in the prior implementation attempt.

**Accepted trade-off:** a modest amount of custom code is needed that a mature SDK would otherwise provide — packet framing and a jitter buffer for out-of-order/lost UDP packets. This is a well-precedented, narrowly-scoped problem (basic VoIP jitter buffering), not comparable in risk to reimplementing WebRTC itself, and it's covered by the same CI discipline (`0001`) as everything else.

**Reversal:** if real-world testing shows the custom jitter-buffer/framing layer is unreliable, LiveKit (self-hosted, Apache 2.0, launched on-demand rather than always-resident) is the fallback — its SDK absorbs exactly the reliability problems a from-scratch attempt would hit. Pion direct is not preferred as a fallback since it offers the infrastructure cost of the WebRTC approach without LiveKit's SDK convenience.
