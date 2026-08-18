# macOS Distribution & Update Options

Research for ticket #19 (child of map issue #4). Question: code-signing / notarization requirements, installer options, and update mechanisms for a **solo-owner-run, native macOS app distributed outside the Mac App Store**, given Lira's multi-component architecture (main app, XPC helpers, resident model process).

Scope note: v1 targets a single owner on a single Mac (see `CONTEXT.md`), so distribution is **Developer ID + notarization** (outside the App Store), not the Mac App Store sandbox path.

---

## 1. Code signing & notarization (non-negotiable for outside-the-App-Store)

Distribution outside the Mac App Store requires **Developer ID signing + notarization**. Apple's notary service is an automated scan (malicious content, code-signing issues) and **is not App Review**. The ticket it issues is consulted by Gatekeeper on first install/run, producing the familiar "Apple notarized this app" dialog.

### Hard requirements (from Apple's "Notarizing macOS software before distribution")

- All executables must have **valid code signatures**.
- Sign with a **Developer ID** certificate (application, kernel/system extension, or installer). Do **not** use Mac Distribution, ad-hoc, or local development certificates.
- Enable the **Hardened Runtime** capability for the app and command-line targets.
- Include a **secure timestamp** with the signature.
- No `com.apple.security.get-task-allow` entitlement set to true.
- Link against macOS 10.9 SDK or later.
- Properly formatted, ASCII-encoded entitlements XML.

Source: Apple, *Notarizing macOS software before distribution* — https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

### What can be notarized

Apple's notary service accepts: **macOS apps**, non-app bundles (e.g. kernel extensions), **disk images (UDIF)**, and **flat installer packages**. So a `.app` alone, a `.dmg` containing it, or a `.pkg` can all be notarized directly.

### When notarization became mandatory

Since **macOS 10.15**, all software built after **June 1, 2019** and distributed with Developer ID must be notarized to run. (Kernel extensions and new Developer ID certs since 10.14.5 were already covered.) So notarization is effectively a hard requirement, not an option, for any current outside-the-Store distribution.

### Developer ID signing certificate

Developer ID certificates are issued under an **Apple Developer Program** membership ($99/year). The **Account Holder** must sign with Developer ID for direct distribution (per Apple's workflow). This matters for a solo owner: one Apple ID membership, certificates in their Mac's keychain.

Source: Apple, *Notarizing macOS software before distribution* (certificate type + "your Account Holder must sign"); Apple, *Share your team's signing certificates* — https://developer.apple.com/documentation/Xcode/sharing-your-teams-signing-certificates

### Automation

Notarization integrates into build scripts via `notarytool` (upload) and `stapler` (staple the ticket to the artifact). `altool` and Xcode ≤13 are no longer accepted since Nov 1, 2023. For an Xcode archive, the Organizer → Distribute → Developer ID → Upload path automates it.

Source: Apple, *Customizing the notarization workflow* — https://developer.apple.com/documentation/security/customizing-the-notarization-workflow

### Hardened Runtime — implications for Lira's multi-process architecture

Hardened Runtime + SIP protects against code injection, DLL hijacking, and memory-space tampering. Key detail for a multi-component app:

- **Entitlements are declared per-executable**; shared libraries, frameworks, and in-process plug-ins **inherit** the host executable's entitlements.
- Exceptions are opt-in entitlements (e.g. `allow-jit` for a JIT engine, `disable-library-validation` to load arbitrary unsigned code). Only the entitlements actually needed should be enabled.
- This applies to **each of Lira's processes** — the main app, XPC helpers, and the resident model process are all separate executables and each needs its own valid signature + hardened runtime, with their own entitlement sets.
- Relevant exclusions Lira may need: `com.apple.security.device.audio-input` (voice), `com.apple.security.personal-information.*` (screen/computer control, contacts), `com.apple.security.cs.allow-jit` (a JIT'ing model runtime, e.g. JAX/CUDA-style), `com.apple.security.automation.apple-events` (controlling other apps).

Source: Apple, *Hardened Runtime* — https://developer.apple.com/documentation/security/hardened-runtime

---

## 2. Installer options

For a single-owner app distributed from a website or GitHub Releases, the realistic options are:

### `.app` inside a `.dmg` (recommended for Lira)
- Simplest UX: mount, drag to `/Applications`, eject. Add an `/Applications` symlink in the image to encourage copying out.
- The DMG itself is a notarizable UDIF image; the embedded `.app` carries the notarization ticket too.
- Everything lives in one self-contained `.app` bundle — works cleanly when **all** of Lira's components are inside the bundle.

Source: Sparkle, *Distributing your App* (recommends a notarized, Developer ID-signed disk image with an `/Applications` symlink); Apple TN2206, *Creating and distributing a disk image* — https://developer.apple.com/library/content/technotes/tn2206/_index.html

### `.zip` / `.tar` / Apple Archive
- Sparkle supports zip, tar, and Apple Archives (`.aar`, macOS 10.15+) for updates.
- **Caveat:** avoid placing anything but the app inside the archive, to minimize **app translocation** issues (running from a quarantine-sealed read-only mount).

Source: Sparkle, *Distributing your App* — https://sparkle-project.org/documentation/

### Flat `.pkg` (only if components must leave the `.app` bundle)
- A pkg is required when something must be installed **outside** the user's app bundle — e.g. a LaunchDaemon under `/Library/LaunchDaemons`, a privileged helper under `/Library/PrivilegedHelperTools`, or a system extension.
- pkgs are notarizable and can run install scripts, so they're the mechanism for root/system-level components.
- **Cost:** heavier UX (installer flow, elevation), harder to update cleanly, and pkg-based updates complicate the auto-update story (Sparkle can drive pkg updates, but they generally require elevation/relaunch and aren't as seamless as in-place `.app` replacement).

### Which does Lira need?
This depends on where the components live:

| Component | If bundled inside `.app` (Contents/Helpers, Contents/XPCServices, Contents/Library/LaunchServices) | If installed system-wide |
|---|---|---|
| Main app | DMG is enough | — |
| XPC helpers | DMG is enough — updated with the app | — |
| Resident model process (LaunchAgent in `~/Library/LaunchAgents`) | DMG is enough — LaunchAgent plist can live inside the bundle and be referenced/copied on first run | Needs `.pkg` if a root LaunchDaemon in `/Library/LaunchDaemons` |

**Recommendation:** keep the resident model process and XPC helpers **inside the `.app` bundle** (the app's own Helpers directories, referenced or copied to `~/Library` as a LaunchAgent on first run), so a single notarized DMG distributes and updates everything. Only adopt a `.pkg` if Lira later requires a privileged, root-running system daemon — that's a real architectural fork with distribution/update consequences, worth a dedicated ADR before it's needed.

Source: Apple, *Notarizing macOS software before distribution* (notarizable deliverables list); Sparkle, *Distributing your App*.

---

## 3. Update mechanism

### Sparkle (recommended) — the de-facto standard for non-App-Store macOS updates

- Open source, MIT-licensed; works with SwiftUI/Cocoa; used by iTerm2, HandBrake, Transmission, etc.
- **Security model:** Sparkle EdDSA (ed25519) signatures on update archives + (optionally) signed appcast feeds. Serving over HTTPS. Optionally signed feeds (`SURequireSignedFeed`) and `SUVerifyUpdateBeforeExtraction` so a compromised update server cannot push a malicious update or redirect users.
- **Architecture fit:** Sparkle updates the **`.app` bundle**. If all of Lira's components are inside the bundle, one update refreshes the app, its XPC helpers, and its embedded model-process helper together — exactly matching the DMG recommendation above.
- **Appcast:** an RSS feed with extra fields; `generate_appcast` produces it and delta updates automatically.
- **Delta updates:** smaller incremental updates between releases.
- **Update sources:** DMG, zip, tarball, Apple Archive, and installer packages.

Sources:
- Sparkle homepage — https://sparkle-project.org/
- Sparkle, *Basic Setup / Distributing your App / Security* — https://sparkle-project.org/documentation/

### Sparkle considerations specific to multi-component / helper apps
- Helper executables embedded in the bundle are code-signed as part of the normal build; updating the bundle updates them. Xcode's Archive → Distribute (Developer ID) ensures Sparkle's helper tools are signed correctly.
- For components that must live **outside** the bundle (privileged helpers, daemons), you need Sparkle **package updates** (`package-updates` doc) with their own install scripts/elevation — a heavier path, consistent with the pkg caveat above.
- Library Validation (part of Hardened Runtime, required for notarization) means Sparkle.framework must be loaded by a properly-signed host; with Developer ID distribution this is satisfied automatically.
- **`CFBundleVersion`** must be an incrementing, properly formatted build number — Sparkle compares these to decide on updates.

Source: Sparkle, *Basic Setup*, *Distributing your App*, *Security*, *Package updates* — https://sparkle-project.org/documentation/

### Custom update approach (possible, not recommended)
A bespoke updater (download, verify checksum/signature, replace `.app`, relaunch) is feasible and gives full control, but you'd be reimplementing security-critical details Sparkle already solves: EdDSA signature verification, delta updates, signed feeds, translocation handling, update scheduling, and UI. For a solo owner, the security review burden of a custom updater is high and error-prone. **Recommendation: adopt Sparkle unless a concrete constraint rules it out.**

---

## 4. Synthesis / recommendation for Lira v1

1. **Join the Apple Developer Program** (one $99/yr membership for the solo owner). Developer ID certs + notarization are mandatory for outside-the-Store distribution since macOS 10.15.
2. **Sign with Developer ID**, enable **Hardened Runtime** on the main app, each XPC helper, and the resident model process, with per-executable entitlements only where needed (audio input for voice, accessibility for computer control, `allow-jit` only if the model runtime JITs). Add a secure timestamp; no `get-task-allow`.
3. **Keep all components inside the `.app` bundle** — XPC helpers and the model-process helper executable bundled, the LaunchAgent plist referenced/copied to `~/Library/LaunchAgents` on first run. This keeps distribution and updates to a single artifact.
4. **Distribute as a notarized DMG** with an `/Applications` symlink (hosted on the project website or GitHub Releases).
5. **Update with Sparkle 2**: EdDSA-signed updates, HTTPS-hosted signed appcast, delta updates; one update refreshes the whole app + helpers. Reuse the same DMG for both first-run download and Sparkle updates.
6. **Defer pkg/privileged-daemon work** until/unless a root system daemon becomes a real requirement; if it does, that's its own ADR (distribution + pkg update path change).

---

## Open questions for the map

- Does the resident model process need to run as a **LaunchAgent** (user space, inside bundle) or a **LaunchDaemon** (root, `/Library`)? The former keeps DMG+Sparkle; the latter forces pkg and heavier updates. (Related to deferred TCC-permission-broker and computer-control-stack decisions in ADR `0006`.)
- Will any component need **JIT / unsigned-library** entitlements (model runtime), and if so which hardened-runtime exceptions are truly required?
- Whether Lira will ship as a **regular app** or a **menu-bar/agent app** affects `.app` packaging only marginally (LaunchAgent vs app launch) — not the distribution model.
