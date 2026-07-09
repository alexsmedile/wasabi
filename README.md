# Wasabi

A slim, low-RAM native macOS shell for your chat apps — WhatsApp Web, Telegram,
and any other messaging service you add by URL, all in one window behind a strip
of vertical icons, without surrendering 5 GB of RAM to an Electron client.

> **Status: beta (0.5.3-beta).** Ships WhatsApp + Telegram out of the box and
> lets you add, rename, reorder, or remove services yourself. Runs logged in and
> snappy; the per-service sleep policy that drives the project toward its <500 MB
> target is implemented and configurable. The sidebar is resizable (View ▸ Sidebar
> Size: Wide / Medium / Compact) with a native full-height layout in Wide, and
> asleep services dim to show reclaimed RAM. Now ships as a **notarized,
> drag-to-Applications DMG** (Gatekeeper-clean, no security warning); a Keychain
> license gate and in-app update notifications are in place for paid distribution.
> The source is **source-available** (PolyForm Noncommercial) — build it yourself
> for free, or buy the notarized auto-updating build (see below).

## Why

Wasabi's selling point is **native optimization, not feature count.** It
intentionally does less than the big multi-chat clients — and runs far lighter
because of it.

Multi-app chat clients (Ferdium, Singlebox, Rambox) each bundle a full Chromium
and start around 2 GB of RAM, climbing to ~5 GB over a workday. Wasabi bets that
a native macOS app on the system's own web engine (WebKit / `WKWebView`) can
deliver the same "all my chat apps in one window" experience for a fraction of
the memory — by being lean on purpose, not by piling on features.

It is **not** a full browser — no address bar, no general browsing. Services are
pinned web apps you add yourself by URL. macOS only, native WebKit, no Electron.

## How it compares

| | **Wasabi** | WhatsApp native app | Beeper | Browser wrappers (Unite, Coherence) |
|---|---|---|---|---|
| **Engine** | Native WebKit (`WKWebView`) | Electron / Catalyst | Electron | Native WebKit (usually) |
| **Multiple services in one app** | ✅ any web app, add by URL | ❌ WhatsApp only | ✅ many, via their bridges | ➖ one app per site (you make many) |
| **RAM (idle, several services)** | **~0 per slept service**, <500 MB target | ~300–700 MB for one | ~1–2 GB+ | ~150–400 MB per wrapped site, all live |
| **Sleeps inactive services to reclaim RAM** | ✅ tears down the WebContent process | ❌ | ❌ | ❌ |
| **Session isolation per service** | ✅ separate `WKWebsiteDataStore` | n/a (single) | server-side accounts | ✅ per app |
| **How messages route** | direct to each web app (your session) | direct | through Beeper's servers/bridges | direct |
| **Privacy** | local only, no middleman | direct | messages traverse a third party | local only |
| **Native, no Electron** | ✅ | ❌ (mostly) | ❌ | ✅ |

**The trade-off is deliberate.** Wasabi ships fewer features than the big browser
wrappers and bridge apps — no unified inbox, no plugins, no cross-service search.
It does one thing: host your web apps with **native efficiency**. Built directly
on the system's WebKit (not a bundled Chromium), with a sleep policy that releases
an inactive service's entire WebContent process, it idles where Electron clients
sit at gigabytes. If you want a feature kitchen-sink, Beeper or Ferdium are richer.
If you want your chats in one native window without surrendering your RAM and
battery, that's the whole point of Wasabi.

## What works today

- **WhatsApp Web + Telegram (WebK)** ready on first launch, each in its own
  isolated `WKWebView` behind a vertical sidebar; click an icon to switch the
  active service.
- **Add any messaging service yourself** — the sidebar "+" takes a URL (a bare
  host like `app.slack.com` works) and a name, and it joins the strip with its
  own isolated session and a favicon icon. Right-click to **rename**, **change
  its URL**, or **remove** it (which deletes its on-disk session), and **drag**
  the icons to reorder. The built-ins are just the starting seed — your list is
  the source of truth from then on.
- **Isolated persistent sessions** — each service has its own
  `WKWebsiteDataStore(forIdentifier:)`, so logins survive relaunch and never
  cross between services. Removing a service deletes its store and login cleanly.
- **Desktop-Safari user agent** per WebView, clearing WhatsApp Web's
  "Browser not supported" wall.
- **Per-service sleep policy** (the RAM lever) — right-click a sidebar icon to
  choose *keep running* / *sleep after 5 min* / *smart adaptive* (the default).
  An inactive service is torn down (its WebKit content process exits, freeing
  the whole heap) and reloads from its persistent store on wake — no re-login.
  Smart Sleep keeps it live for a short grace period after you switch away (so
  flicking between chats doesn't pay a cold reload), then backs off adaptively.
  The choice persists across launches.
- **Resizable native sidebar** — View ▸ Sidebar Size switches between Wide,
  Medium, and Compact (remembered across launches). Wide is a full-height
  source-list layout with the window's own traffic lights inside the sidebar top
  (Finder/Notes style); asleep services dim to show reclaimed RAM, and the active
  service carries a green ring. View ▸ Reset Window Size restores the default
  window.
- **Inactive services back off** — a hidden service reports the Page Visibility
  API (`document.hidden`) so it pauses its own timers and animations like a
  backgrounded browser tab, while staying mounted for instant switch-back. All
  services share one WebKit process pool so memory is coordinated, without any
  session crossing between them.
- **Native macOS notifications** — banners + sound, grouped per service, with
  click-to-activate. Delivered through a `window.Notification` shim
  (`NotificationBridge`) into `UNUserNotificationCenter`, with a 30 s dedup
  window. Gated by sleep policy: a slept service raises none, and notifications
  never keep a service alive.
- **Programmatic app icon** generated from the active service favicons.
- **Native menu icons** — the main menu and the right-click service menu carry
  SF Symbol icons, matching modern macOS menus.
- **In-app update notifications** — a lightweight check (Wasabi ▸ Check for
  Updates…, plus a non-blocking launch check) offers a download when a newer
  version is available. No embedded update framework.
- **License gate (foundation)** — launch is gated on a Keychain-stored license
  key with offline grace, behind a vendor-agnostic backend seam for paid
  distribution. Dev bypasses are compiled out of release builds.

See [`.spectacular/SPEC.md`](.spectacular/SPEC.md) for the authoritative
capability list and [`.spectacular/ROADMAP.md`](.spectacular/ROADMAP.md) for
what's coming next.

## Install

Wasabi ships as a **notarized, Developer ID-signed `Wasabi.dmg`** — open it, drag
Wasabi to Applications, and launch. It's Gatekeeper-clean, so there's no
right-click-to-open or security warning.

The signed, notarized DMG is produced and published by the author; the release
tooling (Developer ID signing, notarization, distribution) is vendor-internal
and not part of the public source.

## Build from source

For development, Wasabi builds with **Command Line Tools only — no Xcode required**.

```sh
scripts/build-app.sh        # compiles Sources/ with swiftc → build/Wasabi.app
open build/Wasabi.app       # launch the locally built app
```

First-time setup to avoid a keychain password prompt on every launch:

```sh
scripts/make-signing-cert.sh   # create the stable local "Wasabi Dev" signing identity
```

Other helpers:

| Script | Purpose |
|--------|---------|
| `scripts/build-app.sh` | Compile + assemble + locally sign `build/Wasabi.app`. |
| `scripts/make-signing-cert.sh` | Create the stable self-signed identity used by the build. |
| `scripts/make-icns.sh` | Regenerate `Resources/AppIcon.icns` from `scripts/make-icon.swift`. |

There is no automated test target yet — verify changes by building and exercising
the affected webview, menu, upload, icon, or sleep-policy behavior.

## Requirements

- macOS 15+ (Apple Silicon).
- Xcode Command Line Tools (`xcode-select --install`).

## Project layout

| Path | Contents |
|------|----------|
| `Sources/` | Swift 6 AppKit + WebKit source (`main.swift`, `AppDelegate.swift`, `MainViewController.swift`, `WebViewController.swift`, `WebViewPool.swift`, `NotificationManager.swift`, `NotificationBridge.swift`, …). |
| `Sources/_swiftui_deferred/` | Parked SwiftUI code, excluded from the CLI build. |
| `Resources/` | App icon and generated assets. |
| `scripts/` | Build, signing, and icon automation. |
| `.spectacular/` | Project workspace — PRD, SPEC, ROADMAP, architecture, and per-feature request docs. |

See [`AGENTS.md`](AGENTS.md) for contributor guidelines (structure, build
commands, coding style, commit conventions), and [`CONTRIBUTING.md`](CONTRIBUTING.md)
for the contributor terms (DCO + commercial-rights grant that keeps the
dual-license model viable).

## Goals (the bar for v1)

- WhatsApp + Telegram both logged in, **well under 500 MB** steady-state idle
  (vs. Ferdium/Singlebox's 2–5 GB) — the headline benchmark.
- Both services asleep: **under 250 MB**.
- **Cold launch under 2 seconds.**
- A full 8-hour workday with no runaway RAM growth, on 8 GB and 16 GB Macs.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE) —
© 2026 Alessandro Smedile. Free to read, build, modify, and use for any
noncommercial purpose; commercial use requires a separate license. The paid,
notarized, auto-updating build and Pro features are distributed only by the
author. Wasabi hosts third-party web services (WhatsApp, Telegram,
…) that are governed by their own terms; this license covers the Wasabi app only.
Privacy: no servers, no telemetry — everything stays in local WebKit storage
([`PRIVACY.md`](PRIVACY.md)).
