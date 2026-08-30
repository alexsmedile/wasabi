# Wasabi documentation

Wasabi is a native macOS WebKit wrapper that keeps chat services isolated and
can tear down inactive views to reclaim memory. Version `0.6.0-beta` introduces
the Wasabi Free/Pro product model, a seven-day Pro trial, contextual upgrade
screens, bounded Smart Sleep background wakes, and hardened WebKit lifecycle
handling.

## Product model

New installations begin a seven-day Pro trial automatically, without an account,
credit card, or onboarding decision. After expiry, Wasabi Free remains fully
usable for two services and preserves every configured service and session.

| Wasabi Free | Wasabi Pro |
|---|---|
| Up to two services | Unlimited services |
| Keep Running, Sleep after 5 minutes, and Sleep Now | Smart Sleep |
| Add, edit, and remove services | Drag to reorder |
| Sessions, notifications, uploads, clipboard, camera, and microphone | Everything in Wasabi Free |

Wasabi shows two unsolicited commercial messages at most: one soft offer after
24 hours and one notice when the trial expires. Other upgrade windows appear only
after the user explicitly selects a locked feature. Pro labels are shown only
while a feature is locked in Wasabi Free; they are hidden during the trial and
after activation.

## Documentation index

- [README](../README.md): overview, installation, source builds, architecture,
  requirements, and Free/Pro comparison.
- [Changelog](../CHANGELOG.md): versioned user-visible changes.
- [Privacy](../PRIVACY.md): local storage, network behavior, and telemetry policy.
- [License](../LICENSE): PolyForm Noncommercial 1.0.0 terms and required notice.
- [Contributing](../CONTRIBUTING.md): DCO, commercial-rights grant, build checks,
  and pull-request expectations.
- [Release status](../STATUS.md): current verification state and remaining private
  distribution gates.

## Source and official builds

The source is public and source-available under the PolyForm Noncommercial
License. Noncommercial users may read, build, modify, and use it under those
terms. Commercial use requires separate permission from the author.

Official paid builds are Developer ID signed, notarized, and distributed by the
author. Public source builds do not include the private signing/notarization
pipeline, production checkout configuration, or an official update artifact.
