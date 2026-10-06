---
schema: make-a-change/todo/v1
extensions:
  - "octopus:all"
---

# TODO — Wasabi

The current public build is `0.6.2-beta` build `14`. It is suitable for a
small, trusted friend beta. Keep the next change set bounded and do not reopen
the completed release unless tester evidence points to a regression.

## Next session

- [ ] Send the notarized DMG to a small group using the public prerelease link
  documented in `STATUS.md` and `docs/RELEASING.md`.
- [ ] Ask testers for their macOS version, Mac model, services used, exact steps,
  expected/actual result, and a screenshot or screen recording when useful.
- [ ] Triage feedback into: release blocker, confirmed bug, product request, or
  WebKit/third-party-service limitation.
- [ ] Run the remaining manual product matrix before promoting beyond a friend
  beta: cold launch/session restore, explicit sleep/wake, notifications,
  upload/download, clipboard, camera/microphone, activation/deactivation,
  licensed third-service switching, and updater behavior.
- [ ] Finish the WIP website in
  the separate `wasabi-website` repository: visually review the aligned
  `0.6.2-beta` page on desktop/mobile, add the dedicated Pro page, and decide
  whether it is ready to publish.
## Website alignment

- [x] Change the primary download and version copy to `0.6.2-beta` and use the
  public release artifact or manifest as the source of truth.
- [x] Explain the automatic seven-day Pro trial, Wasabi Free for two services,
  Pro features, and the limited-time €9.90/US$9.90 one-time launch offer.
- [x] Keep the signed download primary and GitHub/source access secondary.

- [x] Correct the service-organization copy: drag-to-reorder is Pro, not a
  universal Free capability.
- [x] State the notification tradeoff accurately: sleeping services cannot
  notify; Keep Running is the instant-notification option.
- [x] Link Privacy, License, release notes, and source clearly.

- [ ] Add a dedicated Pro information/sales page before pointing “Discover Pro”
  away from checkout.
- [x] Pass the website production build, rendered-page test, and lint.

- [x] Add a stable `/download` page, route every homepage download CTA through
  it, and retain a direct current-DMG fallback.
- [x] Add a guarded `/buy` redirect to the production Lemon Squeezy checkout;
  keep the real URL in ignored local/hosted configuration.
- [x] Set `WASABI_CHECKOUT_URL` as a secret in the hosted Sites environment.
- [x] Choose `https://wasabi.gin.so/` as the first canonical website origin.

- [x] Deploy the updated owner-only Site, verify `/`, `/download`, and `/buy` on
  its Sites hostname, and attach `wasabi.gin.so`.
- [ ] Add the CNAME and two Sites verification TXT records in the `gin.so` DNS
  zone, wait for TLS activation, then verify all three routes on the custom
  hostname.
- [ ] Make the Site public only when the launch is intentional. It remains
  **Only you** after this update.
- [ ] Visually review desktop/mobile, then decide whether the WIP site is ready
  to publish. The in-app browser was unavailable during the 2026-08-30 pass.

## Product hardening

- [ ] Add Swift Testing coverage for Smart Sleep scheduling, sleep policy,
  update-version comparison, licensing persistence, and notification dedup.
- [ ] Add a local repeatable resource-regression check for helper-PID churn,
  idle CPU, WebContent termination, and physical footprint.
- [ ] Replace environment-gated synchronous diagnostics with bounded
  `Logger`/signpost instrumentation.
- [ ] Fix `scripts/measure-ram.sh` so helper-process count is never described as
  live-service count.
- [ ] Revisit the historical four-processes-per-second churn only with new,
  reproducible evidence; do not claim root-cause closure from the current soak.

## Later product work

- [ ] Add Pro conveniences that benefit two-service users without degrading
  Free, starting with custom icons and a keyboard quick switcher.
- [ ] When Xcode 27 and Swift 6.4 are stable, run a compatibility build before
  adopting individual language features.
