# Research: TCC permission-broker architecture options

Ticket: [wayfinder:research #7](https://github.com/Flame119052/Lira-Dev/issues/7) (child of map [issue #4](https://github.com/Flame119052/Lira-Dev/issues/4)).

Lira is architected as multiple components talking to each other over authenticated XPC / owned Unix-socket IPC (carried forward in ADR-0006). Several of those components need macOS privacy permissions — microphone, camera, screen recording, accessibility. ADR-0006 explicitly deferred "TCC permission-broker shape (dedicated XPC helper vs. folded into the main app)" to this milestone. This doc surfaces the real tradeoffs between the two candidate shapes so the decision can be made with the facts, in plain language.

---

## What TCC actually is (plain language)

TCC — Transparency, Consent, and Control — is the macOS system that makes a Mac ask the person using it for permission before an app touches private things: the microphone, the camera, the screen, the ability to drive the keyboard/mouse for accessibility, and more.

Three facts drive every design choice below:

1. **The permission belongs to a signed app, not to a "thing".** When macOS asks "Let Lira use your microphone?", the answer is recorded against Lira's *bundle identifier and code signature* — the digital identity of the app bundle. Apple: "the user must explicitly grant permission for **each app** to access cameras and microphones", and "macOS remembers the user's response to this alert, so subsequent uses … don't cause it to appear again." ([Requesting Authorization for Media Capture on macOS](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos))
2. **The prompt text is the app's own.** When the system asks, it shows a message the app supplies (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSScreenCaptureUsageDescription`, etc.) explaining *why*. If the app uses a private resource without supplying that string, **the system terminates the app**. ([Protected resources](https://developer.apple.com/documentation/bundleresources/protected-resources), [Requesting Authorization for Media Capture on macOS](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit))
3. **These capabilities live in the user session, not in a root daemon.** Microphone/camera/screen-recording/accessibility are things a person grants to a foreground, user-session app. A process running as root (a launch daemon) is a separate identity with its own entitlements — it does not silently inherit the user-granted permissions of the GUI app. ([Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement))

The reason this is a "broker" question at all: Lira's voice capture, screen understanding, and computer control each need different permissions, and they live in different components. Someone has to hold the permission and let the rest of the system use it safely. That "someone" is the broker.

---

## The two candidate shapes

### Option 1 — A dedicated XPC helper that brokers TCC-gated capabilities

One helper process (an **XPC service bundled inside the Lira app**) owns the TCC-gated work. Other Lira components don't touch the microphone, camera, screen, or accessibility APIs directly — they call the helper over XPC, and the helper is the only process that has the permissions.

The crucial technical fact that makes this viable: an **XPC service that ships inside the app's bundle is part of that app's identity**. XPC services are "bundled inside of an app or framework" and launch on demand for a client ([XPC overview](https://developer.apple.com/documentation/xpc), [Creating XPC services](https://developer.apple.com/documentation/xpc/creating-xpc-services)). Because it is embedded in the signed app bundle, the permission the owner grants to "Lira" covers the helper too — **one prompt per capability, granted to the app, and the helper is allowed to use it.** No separate prompts for each component.

Apple's own docs frame XPC exactly this way — as the tool for isolation and shared-resource mediation:

> "Centralize work from multiple processes or **mediate access to a shared resource**." / "**Privilege isolation** to narrow the scope of access for different functionality." ([XPC overview](https://developer.apple.com/documentation/xpc))

Note this means a *bundled XPC service*, not a separately installed *launch daemon* (which runs as root with its own identity — the wrong tool here for the reasons above). "Dedicated XPC helper" in the sense of this ticket is the embedded-service version.

### Option 2 — Fold TCC brokering into the main app process

The main Lira app process holds all the permission strings, prompts, and the actual permission-granted work itself (or directly spawns/controls the components that use them). There is no separate broker process; the app is the trusted boundary.

---

## The real tradeoffs, side by side

| Dimension | Option 1: dedicated XPC helper broker | Option 2: folded into the main app |
|---|---|---|
| **Security / privilege isolation** | Each component can only do what the broker lets it. A compromised component can't directly capture the screen or mic — it has no permission of its own and must ask the broker, which can say no. Smallest privilege surface. (XPC overview: "narrow the scope of access".) | Every component's code shares the app's identity and, effectively, its permissions. One bug anywhere is code that can use the camera. Largest trust surface. |
| **Failure blast radius** | A bug/crash in the helper is contained. Apple: XPC services are "launch[ed] on demand, shut down when idle, and restart[ed] if they crash" — launchd keeps the broker alive (XPC overview). A dead helper disables *that* capability; the rest of Lira keeps running. | A crash in a permission-holding path can take down the app (and a missing usage string is a hard **termination**, per the media-capture doc). One process = one blast radius; no containment. |
| **Complexity to build and maintain** | Higher. You design an XPC protocol, an authenticated boundary, request/reply lifecycle, and keep the broker's code signature/entitlements right. More moving parts. (SMAppService is Apple's modern mechanism for bundling and registering helper executables in the app bundle.) | Lower. No extra process, no IPC protocol, no separate signing surface. Straightforward to start. |
| **Owner-visible permission prompts** | Effectively **identical to Option 2**: because the helper is embedded in the app, the owner sees the same one prompt per capability, attributed to "Lira". The broker can also centralize *explaining* permissions and checking status (`AVCaptureDevice.requestAccess`, ScreenCaptureKit's system content picker) in one well-tested place. | The owner sees one prompt per capability, attributed to "Lira" — the same prompts. No advantage here, and they can surface from scattered places if each component manages its own request. |

### The prompt story is the key surprise

A non-obvious but decisive finding: **the two options look the same to the owner.** Because a bundled XPC service shares the app's identity, Option 1 does *not* produce extra "some helper wants the microphone" prompts. Both shapes show the same system alerts, once per capability, granted to Lira. So the owner-visible-prompt axis does not push you toward Option 2 — the thing that actually differs is how much privilege each component holds once the permission is granted.

Apple even reduces the prompt burden for screen content itself: ScreenCaptureKit's system content-sharing picker (`SCContentSharingPicker`) is the recommended way to let people select *which* window/app is captured, rather than a blanket grant ([ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)). A broker is a good home for that picker too.

### When Option 2 would be simpler and fine

If Lira were a single-process app that never let code touch permissions except in one file, Option 2's blast radius is acceptable and the complexity savings are real. But Lira is explicitly *not* that — it is multi-component with authenticated IPC by design (ADR-0006), and several of its components independently want different permissions.

### Why a root daemon is a trap here (important)

If "dedicated helper" is misread as a *launch daemon* (root, separately signed, installed via `SMAppService.daemon`), that is the wrong direction for TCC. A daemon is a standalone executable with its own identity ([Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)) — it does not carry the GUI app's user-granted mic/camera/screen/accessibility permissions, so it can't broker them. The embedded XPC-service flavor of Option 1 avoids this entirely, which is why this doc treats "dedicated XPC helper" as the embedded-service design.

---

## Bottom line

- **Option 1 (dedicated, *embedded* XPC helper as the TCC broker)** is the fit for Lira's stated architecture: it delivers real privilege isolation (a compromised component can't just capture the screen), contains crashes to one capability, and — because it's embedded in the app bundle — shows the owner the **same one-prompt-per-capability experience as Option 2**.
- The cost is honest: more build/maintenance complexity (a protocol, an authenticated boundary, correct signing/entitlements), which SMAppService and the XPC frameworks make tractable.
- **Option 2** is simpler and acceptable only if Lira were effectively single-process; it is not, so its main appeal (simplicity) is weaker and its main cost (everything shares full permission power) is real.
- **Recommendation for the map:** choose Option 1 — a bundled XPC service brokering TCC-gated capabilities — leaning on the embedded-service identity to keep the permission UX identical to the simpler option while getting the isolation the multi-component design needs.

---

## References

- [XPC overview](https://developer.apple.com/documentation/xpc) — XPC services: mediate shared resources, privilege isolation, bundle inside app/framework, launch-on-demand.
- [Creating XPC services](https://developer.apple.com/documentation/xpc/creating-xpc-services) — service identified by bundle ID; launchd launches and manages it.
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) — modern API for registering helper executables (login items, agents, daemons) inside the app bundle.
- [Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements) — permissions granted via code-signature entitlements; App Sandbox, Hardened Runtime.
- [Protected resources](https://developer.apple.com/documentation/bundleresources/protected-resources) — usage-description strings; system asks the person on the app's behalf.
- [Requesting Authorization for Media Capture on macOS](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos) — per-app mic/camera permission, remembered decision, termination if usage string missing.
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) — screen recording permission (`NSScreenCaptureUsageDescription`) and the system content-sharing picker.
- [Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement) — daemons are standalone identities; separate signing/entitlements.
- [ADR-0006: Carried-forward decisions](https://github.com/Flame119052/Lira-Dev/blob/main/docs/adr/0006-carried-forward-decisions-from-prior-implementation.md) — records this TCC broker-shape question as deferred to this milestone.
