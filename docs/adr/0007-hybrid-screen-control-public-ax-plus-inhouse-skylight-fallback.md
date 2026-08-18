---
status: accepted
---

# Screen control: public Accessibility API first, in-house SkyLight-based fallback for non-AX apps

Corrects an oversimplification in `0006`, which carried forward the prior repo's screen-control decision as "visible... rather than invisible background automation." The prior repo's actual ADR-012 was more nuanced: public Accessibility (AX) actions can run in the background safely; only raw coordinate clicking needed a visible takeover, and it explicitly rejected depending on private SkyLight/CGS APIs as "fragile and unsuitable as a required product path."

Research (2026-08-18) confirmed *why* that split exists: OpenAI Codex's own "doesn't steal your mouse" background mode, and Cua's equivalent, both depend on undocumented private macOS `SkyLight` internals (`SLPSPostEventRecordTo`, `SLEventPostToPid`, and an accessibility-observer trick to keep occluded Electron apps' UI trees alive) to make a non-frontmost window accept input without raising it. None of this is Apple-documented; some of it doesn't appear in Apple's own headers. The public AX framework alone only reliably covers apps with real accessibility support — it can't deliver a click to a non-frontmost canvas-based or poorly-instrumented app without the same private trick.

**Decision:** a hybrid, not a single mechanism.

1. **Default path — public AX only.** For any app with real accessibility support (the large majority of native/well-built Mac apps an owner actually uses: Mail, Notes, Safari, Xcode, Slack, Finder, System Settings, etc.), Lira acts via `AXUIElementPerformAction`/`AXUIElementSetAttributeValue` on the target window without raising it. Fully Apple-documented, zero breakage risk, matches Codex's non-intrusive experience exactly for this majority case.
2. **Fallback path — an in-house SkyLight-based layer, inspired by (not copied verbatim from, though MIT permits copying) Cua's `cua-driver`.** For the minority of apps with poor/no accessibility support (canvas-based tools, some Electron apps, games), Lira uses the same category of private "focus-without-raise" technique Codex and Cua both rely on, to preserve the non-intrusive goal even for these apps, accepting the associated fragility.
3. Reference implementation for the fallback path may draw directly on `cua-driver`'s approach and code — it's MIT-licensed (verified directly against the repo, not assumed), so this only requires a standard attribution notice, no license obligation on Lira itself.

**Known risk, accepted with mitigation:** the fallback path depends on undocumented internals Apple can change without warning on any macOS update, with no official support path. Mitigation: the fallback path must be covered by Lira's own CI (per `0001`'s trust model) so a macOS update breaking it is caught by an automated test failing, not silently discovered by the owner mid-task; and the fallback must degrade to the already-decided visible-foreground-takeover behavior (per the original per-app-scoped, visible design) rather than fail silently or crash, if the private call ever stops working.
