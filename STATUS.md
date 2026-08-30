# Status — Wasabi

**Last updated:** 2026-08-30
**Current objective:** Publish `0.6.2-beta` build `14` through the private distribution pipeline.
**Overall state:** Source and notarized DMG are verified; commit/tag and public artifact/manifest publication remain.

---

## Verified release work

- Wasabi Free/Pro: automatic seven-day Pro trial, one 24-hour offer, contextual feature gates, one non-blocking expiry notice, and preserved services/sessions.
- Smart Sleep: focus-aware grace, bounded 5/15/60-minute refresh cadence while Wasabi is active, load timeout, failure backoff, and a three-failure circuit breaker.
- Notifications: native per-service banners, click-to-select, and 30-second exact-repeat deduplication using service + tag + title + body. Product/UI copy now states that Keep Running favors instant notifications, while sleeping services cannot notify.
- Uploads/downloads: file and folder pickers honor WebKit selection parameters; downloads use sanitized collision-safe names in `~/Downloads`, reveal in Finder, and notify when permitted.
- WebKit lifecycle: page visibility follows app/service focus, asleep views are removed from the hierarchy, file drops retain `DataTransfer.files`, and failed WebContent loads cannot create an automatic reload loop.
- Update flow: the app checks the public release manifest and offers newer builds.
- Resource soak from the 0.6.0 candidate: stable helper PIDs during a ten-minute foreground/background/service-switch run, with no target IOSurface errors, WindowServer transaction timeouts, or WebContent termination. This supports a hardening claim, not root-cause closure for the historical four-processes-per-second incident.

## Release metadata

- Marketing version: `0.6.2-beta`
- Build: `14`
- Planned tag: `v0.6.2-beta`
- Public artifact repository: `gin-so/wasabi-releases`
- Production checkout, Pro information URL, Developer ID identity, and notary profile remain vendor-only and gitignored.
- Artifact: `build/Wasabi.dmg` · SHA-256 `d6a9a84548d47181e1e7dc39d92f5af39d9b518d2109a4b31b7bebb387f08c18`

## Known constraints

- A sleeping service has no WebView and cannot receive a notification. Smart Sleep periodically refreshes only while Wasabi is active; use Keep Running for services where notification latency matters.
- WebKit may allocate multiple helper processes for one WebView. Helper count is not live-service count; `scripts/measure-ram.sh` remains useful for aggregate footprint but its service-count wording is not authoritative.
- Whole-app memory depends on the hosted sites. Marketing may claim reclaimed memory for slept services, not a fixed sub-500 MB total while arbitrary web apps remain live.
- The historical graphics/process churn was not reproduced and is not conclusively root-caused.
- There is no committed automated test target. Final confidence still depends on targeted manual coverage of session restore, sleep/wake, notifications, uploads/downloads, clipboard, media permissions, licensing, third-service switching, and updates.

## Release checklist

1. [x] Align source metadata, README badge, changelog, docs, and agent guidance on `0.6.2-beta` build `14`.
2. [x] Regenerate the Xcode project and pass development, release-mode, and Xcode Release builds.
3. [x] Confirm production checkout/Pro URLs are injected and development bypass markers are absent.
4. [x] Developer ID sign with hardened runtime and timestamp; notarize and staple the app and DMG.
5. [x] Verify strict code signing, stapler validation, and Gatekeeper acceptance.
6. [ ] Review the bounded staged diff and secret scan; DCO-sign the release commit and push `v0.6.2-beta`.
7. [ ] Publish `Wasabi.dmg` to `gin-so/wasabi-releases` and update `latest.json`.

## After release

- Add focused Swift Testing coverage for sleep scheduling, licensing/version comparison, persistence, and notification deduplication.
- Add a repeatable resource-regression harness for helper churn, idle CPU, WebContent termination, and physical footprint.
- Replace environment-gated synchronous diagnostics with bounded Logger/signpost instrumentation.
- Correct `scripts/measure-ram.sh` so it never equates WebContent-process count with live-service count.
