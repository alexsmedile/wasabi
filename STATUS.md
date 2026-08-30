# Status — Wasabi

**Last updated:** 2026-08-27
**Current objective:** Finish the `0.5.5-beta` release gates and publish through the private distribution pipeline.
**Overall state:** Release candidate is code-complete and passed the bounded resource soak · Publication remains conditional on the manual product matrix and private signing/notarization gates.

---

## 1. Verified Completed Outputs

- `Sources/VisibilityBridge.swift`, `Sources/MainViewController.swift`: app-wide page visibility is propagated, including hidden-from-document-start offscreen loads.
- `Sources/SleepPolicy.swift`, `Sources/WebViewPool.swift`: Smart Sleep uses a 5/15/60-minute cadence, pauses offscreen wakes while Wasabi is inactive, waits for navigation, times out stalled loads, backs off failures, and opens a breaker after three consecutive failures.
- `Sources/WebViewController.swift`: WebContent termination is observed without automatic reload; stale load callbacks are one-shot and generation-guarded.
- `project.yml`: parked SwiftUI sources are excluded from XcodeGen and camera/microphone plist values are preserved.
- `build/Wasabi.app`: `WASABI_RELEASE=1 scripts/build-app.sh` completed; the app passes strict code-sign verification, contains `LemonSqueezyBackend`, and does not contain the development stub markers.
- Xcode Release build: Swift 6 Release configuration completed successfully with code signing disabled for compilation verification.
- Release metadata: `project.yml`, the CLI app bundle, README badge, and changelog are aligned on `0.5.5-beta` build `11`. CLI builds explicitly use Swift 6 language mode and treat warnings as errors.
- Runtime soak: a 10-minute release-candidate run covered foreground use, a WhatsApp → Telegram switch, return switching, and more than six minutes backgrounded. The helper set changed once for the expected new Telegram WebContent process, then all five helper PIDs remained stable; no rapid spawn/exit churn occurred.
- Background resource gate: the UI settled to 0.0–0.6% CPU and helper CPU was normally in the low single digits. Two brief WebContent spikes occurred without sustained load or PID changes. Foreground stack samples taken during UI automation were dominated by macOS/WebKit accessibility traversal and are not valid idle measurements.
- Graphics/process gate: from the candidate launch at 16:49:36 through the end of the soak, unified logs contained zero target IOSurface `fClientTask` errors and zero WindowServer `transaction timed out` events. No monitored WebContent process terminated.
- Published update manifest: still advertises `0.5.4-beta`, so `0.5.5-beta` is available as the next patch version.

## 2. Active Decisions & Constraints

- **Memory policy remains user-controlled:** `keepRunning` intentionally retains a service's WebView; the current local configuration keeps WhatsApp running while Telegram uses Smart Sleep.
- **Crash-loop recovery is conservative:** Wasabi records WebContent termination but does not immediately reload a failed page. Manual selection/reload is the recovery boundary.
- **Public repository lacks distribution tooling:** Developer ID packaging, notarization, stapling, DMG creation, and update-manifest publication remain vendor-internal.
- **Spectacular reduced mode:** `.spectacular/PROJECT.md` and the generated mechanical interface are absent; no governed Mission completion claim can be recorded from this workspace.

## 3. Known Issues & Release Gates

- The locally verified release-mode app has empty `WASABICheckoutURL` and `WASABIProInfoURL` values; the private release pipeline must inject the production checkout and Pro landing-page URLs.
- The intermittent incident is not conclusively root-caused. The prior four-processes-per-second churn was not reproduced, and its frequency cannot be explained by the former one-minute Smart Sleep timer. This release may claim resource hardening, not root-cause closure.
- Final physical footprint was 1,671 MB: Wasabi UI 72 MB, shared GPU/network helpers 122 MB, and WebContent 1,477 MB (including a 1,265 MB active/retained WhatsApp process). This exceeds a blanket sub-500 MB whole-app claim, but the native wrapper itself remains small and inactive pages throttle correctly. Marketing should describe reclaimed memory for *slept services*, not promise a fixed total while arbitrary web apps remain live.
- `scripts/measure-ram.sh` treats each Wasabi-attributed WebContent PID as one live service. WebKit may use multiple content processes for a single `WKWebView`, so the total physical-footprint sum is useful but the reported live-service count is not authoritative.
- There is no automated test target. Cold launch/session restore, notifications, uploads/downloads, clipboard, camera/microphone, license activation/deactivation, and update checking still require final manual release-candidate coverage. A third-service switch was blocked by the expected local Pro license gate and therefore was not validated during this soak.
- The worktree contains the patch plus pre-existing uncommitted `README.md` licensing documentation. The intended release diff must be reviewed and committed as a bounded set.

## 4. Next Concrete Steps (Ordered)

1. [x] Align `0.5.5-beta` build `11`, the README badge, changelog, Swift 6 CLI mode, and warnings-as-errors across both build paths.
2. [x] Complete a 10-minute foreground/background and service-switch soak with stable helper PIDs and no target graphics errors.
3. [ ] Exercise the remaining manual release matrix: automatic first-launch Pro trial, persisted trial start, one-time Upgrade offer after 24 hours, expiry fallback to Community, checkout/key-entry flow, cold launch, existing sessions, explicit sleep/wake, notifications, file upload/download, clipboard, camera/microphone, licensed third-service switching, activation/deactivation, and update check.
4. [ ] Build through the private distribution pipeline with the production checkout URL; verify Developer ID signature, notarization, staple, DMG launch, and Gatekeeper assessment.
5. [ ] Review the final bounded diff, commit/tag `v0.5.5-beta`, publish the DMG, and update `latest.json` only after all gates pass.
6. [ ] After the patch release, add focused Swift Testing coverage, a repeatable resource-regression harness, bounded Logger/signpost diagnostics, and correct `measure-ram.sh`'s live-service wording.
