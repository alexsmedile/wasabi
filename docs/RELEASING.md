# Publishing and releasing Wasabi

This is the reusable checklist for distributing a beta and publishing a new
official build. It records public facts only. Signing identities, checkout
configuration, notary credentials, and vendor scripts remain in ignored local
configuration and must never be committed.

## Current distributable beta

- Version: `0.6.2-beta`
- Build: `14`
- Release: <https://github.com/gin-so/wasabi-releases/releases/tag/v0.6.2-beta>
- Artifact SHA-256:
  `d6a9a84548d47181e1e7dc39d92f5af39d9b518d2109a4b31b7bebb387f08c18`
- Requirements: Apple Silicon, macOS 15 or later
- State: Developer ID signed, notarized, stapled, and Gatekeeper accepted

## Current website state

- Source: `gin-so/wasabi-website` `main`
- Private Sites deployment:
  <https://wasabi-macos-app.alexsmedile.chatgpt.site>
- Canonical origin: <https://wasabi.gin.so/> (attached; DNS and TLS pending)
- `/download`: verified against the current signed DMG
- `/buy`: verified against the production Lemon Squeezy checkout
- Access: owner-only. Do not make the Site public until launch is intentional.

This build is appropriate for a small friend beta. Do not describe it as a
stable release while the full manual matrix and broader field testing remain
open.

## Friend-beta hand-off

1. Share the public release page above, not an ad-hoc unsigned app archive.
2. Tell testers to download the DMG, drag Wasabi to Applications, and launch it.
3. Explain that the seven-day Pro trial starts automatically with no card and
   Wasabi Free remains available for two services afterward.
4. Explain the notification tradeoff: **Keep Running** provides immediate web
   notifications at a higher memory cost; sleeping policies prioritize memory.
5. Ask testers to report:
   - macOS version and Mac model;
   - Wasabi version/build;
   - affected service and sleep policy;
   - exact reproduction steps;
   - expected and actual result;
   - screenshot, recording, or crash report when available.
6. Do not distribute personal license keys, signing material, checkout secrets,
   notary credentials, or files from ignored vendor-only directories.

## Before cutting the next version

- [ ] Define the bounded change set and update `CHANGELOG.md`.
- [ ] Align marketing version/build in `project.yml`,
  `scripts/build-app.sh`, the README badge, and generated Xcode metadata.
- [ ] Regenerate the Xcode project with `xcodegen generate`.
- [ ] Run the Swift 6 warnings-as-errors development and Release builds.
- [ ] Run focused tests/checks for every changed behavior.
- [ ] Run the manual product matrix:
  - cold launch and session restore;
  - explicit sleep/wake and service switching;
  - foreground/background notifications;
  - file/folder upload and download;
  - clipboard;
  - camera and microphone permissions;
  - trial persistence and offer/expiry screens;
  - license activation and deactivation;
  - licensed third-service switching;
  - updater behavior.
- [ ] Run a foreground/background/service-switch resource soak and check helper
  churn, idle CPU, WebContent termination, physical footprint, IOSurface noise,
  and WindowServer timeouts.
- [ ] Confirm production checkout and Pro information URLs are injected.
- [ ] Confirm development license bypass/stub markers are absent from the
  production binary.
- [ ] Review the bounded diff, run a secret scan, and verify DCO sign-off.

## Produce and verify the official artifact

- [ ] Build in the vendor release configuration.
- [ ] Sign the app with Developer ID, hardened runtime, and a secure timestamp.
- [ ] Notarize the app and staple the accepted ticket.
- [ ] Create and sign the DMG.
- [ ] Notarize and staple the DMG.
- [ ] Validate strict code signing and both stapled tickets.
- [ ] Verify Gatekeeper accepts both the app and DMG as Notarized Developer ID.
- [ ] Record the final DMG SHA-256.

## Publish

- [ ] For the website, configure `WASABI_CHECKOUT_URL` in the hosted Sites
  environment; never commit the production URL or vendor credentials.
- [ ] Verify the deployed `/download` page reaches the current signed DMG and
  deployed `/buy` redirects to the intended Lemon Squeezy checkout.
- [ ] Attach a custom domain only after it is purchased and selected. The
  relative routes work on the temporary Sites URL in the meantime.
- [ ] Commit the reviewed source release with DCO sign-off.
- [ ] Create the annotated `v<version>` tag on that exact source commit.
- [ ] Push the release commit and tag.
- [ ] Publish the DMG as a prerelease for beta versions.
- [ ] Verify the hosted asset name, size, and SHA-256.
- [ ] Update `latest.json` only after the release asset is live.
- [ ] Verify the manifest version, notes, and direct download URL.
- [ ] Confirm the in-app updater sees the intended release ordering.
- [ ] Update `STATUS.md` with the public URL, digest, completed gates, and any
  manual-test caveats.

## Promotion rule

Promote a beta beyond friends only after the manual matrix passes and feedback
shows no release-blocking crash, session-loss, licensing, update, or runaway
resource regression. The historical process/graphics burst remains unresolved
unless it is reproduced with evidence; absence during a soak is hardening
evidence, not proof of root cause.
