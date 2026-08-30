<div align="center">

<img src="docs/assets/wasabi-ui.svg" width="620" alt="Wasabi — a vertical service sidebar beside a chat window, with inactive services dimmed and asleep" />

# Wasabi

**For people who live in their chat apps — and resent what Electron costs their Mac.**

One native window. Every service isolated. Inactive ones torn down to reclaim their RAM.

[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-15%2B-lightgrey)
![Version](https://img.shields.io/badge/version-0.6.0--beta-green)
![Swift](https://img.shields.io/badge/Swift-6-orange)

</div>

---

## What it is

Wasabi hosts your web chat apps — WhatsApp Web, Telegram, and anything you add
by URL — in a single native macOS window, each behind a vertical icon sidebar.

It runs on the system's own web engine (WebKit / `WKWebView`), not a bundled
Chromium. And it does the one thing no browser wrapper does: when you switch
away from a service, Wasabi can **tear it down entirely** — the whole WebContent
process exits and its RAM goes back to your Mac. Switch back and it reloads from
its own persistent session, still logged in.

It is **not** a browser. No address bar, no general browsing. Just your chats,
pinned, isolated, and light.

## How it compares

| | **Wasabi** | WhatsApp app | Beeper | Browser wrappers (Unite, Coherence) |
|---|---|---|---|---|
| **Engine** | Native WebKit | Electron / Catalyst | Electron | Native WebKit (usually) |
| **Many services, one app** | ✅ any web app, add by URL | ❌ WhatsApp only | ✅ via their bridges | ➖ one app per site |
| **RAM, idle** | **~0 per slept service** | ~300–700 MB for one | ~1–2 GB+ | ~150–400 MB per site, all live |
| **Sleeps inactive services** | ✅ exits the WebContent process | ❌ | ❌ | ❌ |
| **Session isolation** | ✅ separate data store per service | single | server accounts | ✅ per app |
| **How messages route** | direct to each web app | direct | via Beeper's servers | direct |
| **Privacy** | local only, no middleman | direct | traverse a third party | local only |
| **Native, no Electron** | ✅ | ❌ (mostly) | ❌ | ✅ |

**The trade-off is deliberate.** Wasabi ships fewer features than the bridge
apps — no unified inbox, no plugins, no cross-service search. It does one thing:
host your web apps with native efficiency, and idle near zero where Electron
clients sit at gigabytes. If you want a feature kitchen-sink, Beeper or Ferdium
are richer. If you want your chats in one native window without surrendering your
RAM, that's the whole point of Wasabi.

## What you get

| | |
|---|---|
| **WhatsApp + Telegram on first launch** | Each in its own isolated `WKWebView`; click a sidebar icon to switch. |
| **Add any service by URL** | The "+" takes a URL (`app.slack.com` works) and a name. Rename, re-URL, remove, or drag to reorder. Built-ins are just the seed — your list is the source of truth. |
| **Per-service sleep policy** | Right-click an icon: *keep running* / *sleep after 5 min* / *smart adaptive*. A slept service exits its content process and reloads on wake — no re-login. |
| **Isolated persistent sessions** | Each service has its own `WKWebsiteDataStore`, so logins survive relaunch and never cross between services. Removing one deletes its store cleanly. |
| **Native notifications** | Banners + sound, grouped per service, click-to-activate — bridged into `UNUserNotificationCenter`. A slept service raises none. |
| **Resizable native sidebar** | Wide / Medium / Compact (remembered). Wide is a full-height source-list layout; asleep services dim to show reclaimed RAM. |
| **Dynamic Dock icon** | Generated from your active services' favicons. |
| **In-app update check** | A lightweight check offers a download when a newer version ships. No embedded update framework. |

## Free and Pro

Wasabi uses one app and a simple feature unlock. New users start with **Pro free
for 7 days**, automatically—no account or card required. After the trial,
**Wasabi Free remains available for up to two services.** Sessions and settings
stay safe; nothing is deleted when the trial ends.

| Wasabi Free | Wasabi Pro |
|---|---|
| Up to 2 services | Unlimited services |
| Keep running, Sleep after 5 min, and Sleep now | Smart Sleep with adaptive background sync |
| Add, edit, and remove services | Drag to reorder services |
| Sessions, notifications, uploads, clipboard, camera, and microphone | Everything in Wasabi Free |

**Limited-time launch offer: Wasabi Pro — €9.90 in Europe or US$9.90 in the
United States.** Unlimited services, Smart Sleep, and custom organization.
One-time purchase; no subscription.

## Install

Wasabi ships as a **notarized, Developer ID-signed DMG** — open it, drag Wasabi
to Applications, launch. Gatekeeper-clean, so no right-click-to-open or security
warning. The signed, auto-updating build and Pro features are distributed by the
author.

Prefer to build it yourself? See below — it's free.

## Build from source

**Command Line Tools only — no Xcode required.**

```sh
scripts/make-signing-cert.sh   # one-time: stable local "Wasabi Dev" signing identity
scripts/build-app.sh           # compile Sources/ with swiftc → build/Wasabi.app
open build/Wasabi.app
```

By default, `build-app.sh` creates a **development build**. Its license backend
is an offline stub that accepts demo keys only, in the form
`WASABI-ABCD-1234-XYZ9`; real Lemon Squeezy keys will be rejected. To test the
real Lemon Squeezy activation flow, build in release mode:

```sh
WASABI_RELEASE=1 scripts/build-app.sh
open build/Wasabi.app
```

This build uses the Lemon Squeezy License API and accepts UUID-shaped Lemon
Squeezy keys. It contains no store API secret; the user’s license key is sent
directly to Lemon Squeezy for activation and validation.

| Script | Purpose |
|--------|---------|
| `scripts/build-app.sh` | Compile + assemble + locally sign `build/Wasabi.app`. |
| `scripts/make-signing-cert.sh` | Create the stable self-signed identity the build uses. |
| `scripts/make-icns.sh` | Regenerate `Resources/AppIcon.icns`. |
| `scripts/measure-ram.sh` | Measure the real per-process memory footprint (the headline benchmark). |

A source build does not auto-update. Development builds use the demo license
stub; release-mode source builds use Lemon Squeezy, but still use local signing
and are not the notarized distribution build. There is no automated test target
— verify changes by building and exercising the affected behavior (webview,
menu, license activation, upload, notifications, sleep/wake).

## How it works

**Sleep is the RAM lever.** One service is always live (the active one). The rest
follow their per-service policy. When a service sleeps, its `WKWebView` is torn
down so WebKit can release its content resources. Waking rebuilds it from the
persistent data store, so you stay logged in. Smart Sleep periodically performs
a short, bounded background wake while Wasabi is active, using a 5/15/60-minute
idle cadence, then sleeps the service again. This balances message freshness with
memory savings; it does not promise that every wake will be instant.

**Isolation lives in the data store, not the process.** Every service is keyed to
a stable `WKWebsiteDataStore(forIdentifier:)`, so cookies and sessions do not
cross. WebKit remains responsible for allocating and reusing its helper processes;
their count is not a reliable count of live services.

## Requirements

- macOS 15+ (Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`) — only to build from source

## Who it's for

- People who keep several chat apps open all day and feel the RAM cost
- Mac users who'd rather run native WebKit than yet another Electron client
- Anyone who wants their web chats isolated, logged in, and light — in one window

## Who it's not for

- People who want a unified inbox, plugins, or cross-service search — that's Beeper/Ferdium
- People who want general web browsing — Wasabi has no address bar by design
- Windows or Linux users — macOS only

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE) —
© 2026 Alessandro Smedile. Free to read, build, modify, and use for any
noncommercial purpose; commercial use requires a separate license. The paid,
notarized, auto-updating build and Pro features are distributed only by the
author. Wasabi hosts third-party web services (WhatsApp, Telegram, …) governed
by their own terms; this license covers the Wasabi app only.

**Documentation:** see [`docs/README.md`](docs/README.md) for the product,
development, privacy, licensing, and release-document index.

**Contributing:** see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the contributor
terms (DCO + commercial-rights grant that keeps the dual-license model viable),
and [`AGENTS.md`](AGENTS.md) for build, structure, and style.

**Privacy:** no servers, no telemetry — everything stays in local WebKit storage
([`PRIVACY.md`](PRIVACY.md)).
