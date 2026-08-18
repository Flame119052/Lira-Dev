---
status: accepted
---

# Distribution: ad-hoc signing, no notarization, DMG + Sparkle 2

Reconsidered after the owner ruled out the $99/year Apple Developer Program membership that Developer ID signing and notarization both require.

**Decision:** self-sign ad-hoc (free, no Apple Developer account) rather than Developer ID + notarize. Ship as a DMG; update via Sparkle 2 (its own EdDSA update-signing is independent of notarization and stays free/self-managed either way). This matches the prior implementation's own packaging approach, adopted for the same reason: personal, single-owner use, not public distribution — release is explicitly not a v1 goal (owner, 2026-08-17).

**Consequence:** macOS Gatekeeper shows its unverified-developer warning on first launch (and possibly after some updates); the owner right-clicks → Open once, or approves it in System Settings → Privacy & Security. Minor recurring friction, not a functional blocker.

**Reversal:** if distributing to other people becomes a real goal later, a paid Developer ID membership becomes worth it at that point — deferred, not decided now.
