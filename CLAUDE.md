# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Wasabi is a native macOS (AppKit + WebKit, Swift 6) shell that hosts pinned web apps
(WhatsApp Web, Telegram WebK) each in its own `WKWebView`, behind a vertical icon
sidebar. The bet: a single native app on the system `WKWebView` replaces an Electron
multi-chat client at a fraction of the RAM. It is **not** a browser — no address bar,
no general browsing. The service list is **user-managed**: a persisted
`ServiceRegistry` (seeded once from `Service.defaults`) lets the user add, remove,
rename, and reorder services via the sidebar; built-ins are just the seed.

## Build & run

No Xcode required — Command Line Tools only.

```sh
scripts/build-app.sh         # swiftc-compile Sources/*.swift → build/Wasabi.app, then sign
open build/Wasabi.app
scripts/make-signing-cert.sh # one-time: create the stable "Wasabi Dev" signing identity
scripts/make-icns.sh         # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
WASABI_DEBUG_LOG=1 open build/Wasabi.app   # enable /tmp/wasabi.log (off by default; see DebugLog.swift)
```

`build-app.sh` compiles only the top level of `Sources/` (`find -maxdepth 1`) — anything
in `Sources/_swiftui_deferred/` is intentionally excluded from the CLI build. `project.yml`
+ `xcodegen generate` exists as an alternate Xcode path but the swiftc script is the
primary build.

**There is no test target.** Verify every change by building and exercising the affected
behavior by hand (webview, menu, upload, notifications, icon, sleep/wake). Note manual
verification steps in commits/PRs.

### Signing gotcha
The build signs with a self-signed cert looked up **by SHA-1 hash via `security find-identity`
WITHOUT `-v`** — the `-v` flag and `-p codesigning` both hide the untrusted self-signed cert.
`--options runtime` (Hardened Runtime) is deliberately omitted: it tightens the keychain ACL
on the `WKWebsiteDataStore` encryption key and re-triggers the password prompt on every clean
rebuild for zero benefit in local-only distribution. A changed binary (new CDHash) still
prompts the keychain once per rebuild — expected, not a bug.

## Architecture

Pure-AppKit entry (`main.swift` → `AppDelegate` → `MainViewController`); no nib/storyboard,
no SwiftUI in the build. Because there's no storyboard, **the main menu must be installed
programmatically** (`MainMenu.build()` in `AppDelegate`) — without it ⌘C/⌘V/⌘X/⌘A have no
target in the responder chain and are silently swallowed (right-click still works, since
that's WebKit's own menu).

Ownership chain:
- **`ServiceRegistry`** — the persisted, mutable source of truth for the service list
  (`UserDefaults` key `wasabi.services.v1`, seeded once from `Service.defaults`). Add /
  remove / rename / reorder mutate it and fire `onChange`; `MainViewController` subscribes
  and applies the delta. `Service` is `Codable` for this store.
- **`MainViewController`** — sidebar of service buttons + a single content container. Builds
  one `WebViewController` per service from `registry.all()`, hands them to `WebViewPool`, and on
  `select(serviceID:)` mounts the chosen WebView, unmounts the siblings (they're
  `removeFromSuperview`d, not just hidden — see drag-drop below), and tells the pool
  who's active. Selecting a service that was asleep shows a "Waking…" overlay (moon +
  spinner) over the blank cold-reloading WebView, faded out on the controller's `onDidFinish`
  (min-hold 0.5 s so a warm reload doesn't flash). `reloadServices()` applies registry deltas
  (add/edit/reorder) incrementally; the "+" opens `AddServiceSheet`; right-click →
  Sleep now / policy / Edit…/Remove. Also owns the dynamic Dock icon (`AppIconController`,
  favicon grid).
- **`WebViewController`** — owns exactly one `WKWebView` for one service. Builds it lazily
  (`webView` getter rebuilds after sleep), loads the URL, and is the `WKNavigationDelegate` /
  `WKUIDelegate` / `WKDownloadDelegate`. `sleep()` tears the WebView down (releasing the
  WebContent process — the only way to reclaim per-service RAM); `wake()` rebuilds from the
  **persistent** data store, so no re-login.
- **`WebViewPool`** — owns the sleep/wake lifecycle. One service is `active` (always live);
  the rest follow their per-service `SleepPolicy` (keepRunning / autoSleepTimer / smartSleep)
  via per-service `Timer`s. Policy is persisted to `UserDefaults` (`wasabi.sleeppolicy.<id>`)
  and changed from the sidebar right-click menu. Smart Sleep's pre-teardown grace is
  **focus-aware** (observes `NSApplication` active/resign): a long window while Wasabi is
  frontmost (`SmartSleepSchedule.graceForeground`, you're still tab-switching), a short one
  once you leave for another app (`graceBackground`); leaving mid-grace re-arms any still-awake
  service onto the short window. `sleepNow(_:)` backs the right-click "Sleep now" — tear a
  service down immediately regardless of policy (no-op for the active or already-asleep one).

### Per-service isolation & the shared process pool
Session isolation is owned **solely** by `config.websiteDataStore =
WKWebsiteDataStore(forIdentifier: DataStoreID.uuid(for: service.id))` — a stable per-service
UUID keying an on-disk store, so logins/cookies survive sleep/wake and relaunch and never
cross services. All WebViews **share one `WKProcessPool`** (`WebViewController.sharedProcessPool`)
so WebKit coordinates memory across WebContent processes; this does NOT leak sessions because
isolation lives in the data store, not the pool. Don't "fix" isolation by giving each service
its own pool.

### Bridges — the document-start injection pattern
WKWebView's public macOS API is missing several web platform features that WhatsApp/Telegram
need; each gap is filled by a bridge that injects a `WKUserScript` at `.atDocumentStart` and
(where needed) registers a `WKScriptMessageHandler`. All are installed in
`WebViewController.makeWebView()` and rebuilt on every wake. When adding a capability the web
app expects but WKWebView lacks, follow this same pattern rather than reaching for private SPI.

- **`NotificationBridge`** + **`NotificationManager`** — macOS WKWebView has *no* Web
  Notification API. The bridge patches `window.Notification` to report `granted`, resolve
  `requestPermission()` immediately, and forward `new Notification(...)` to native;
  `NotificationManager` re-emits via `UNUserNotificationCenter` (30 s dedup, click-to-activate).
  **Critical:** an unanswered permission/open-panel completion handler crashes the WebContent
  process — this was the "background sync popup crash." Always answer completion handlers exactly once.
- **`ClipboardBridge`** — shims `navigator.clipboard` (denied by default) to `NSPasteboard`.
- **`VisibilityBridge`** — drives the Page Visibility API. A hidden-but-mounted WKWebView is
  still "visible" to WebKit (timers/rAF keep running). There's no public API to force page
  visibility (`_setPageVisibilityState:` is SPI), so this reports `document.hidden`/`visibilityState`
  to the page and lets well-behaved apps back off. The active service is always `setVisible(true)`;
  visibility is re-asserted in `didFinish` because a page that loaded while inactive starts at
  the shim's `visible` default.

### File upload & drag-drop (`NonNavigatingWebView`, WKUIDelegate)
Two distinct mechanisms, both previously broken (see `FEEDBACKS.md`):
- **Attach button** (`<input type=file>`): `WebViewController` implements
  `runOpenPanelWith` → native `NSOpenPanel`. Without a `WKUIDelegate` the input does nothing,
  and an unanswered handler crashes the WebContent process.
- **Drag-drop**: WKWebView's default drag destination *navigates to* a dropped file URL (a
  PDF opens in-view instead of attaching). The fix is in `WebViewController`'s
  `decidePolicyFor navigationAction`: any main-frame navigation to a `file://` URL is
  `.cancel`led, so the page's own DOM drop handler keeps the file for upload. Do **not**
  strip the file drag types from the view to suppress this — WebKit needs those types
  registered to populate `DataTransfer.files`, and stripping them races
  WebContent-process relaunches (shared pool + sleep/wake), producing a "drop overlay
  shows but nothing uploads" intermittency. **Only the active service may be mounted**:
  an inactive service kept in the view hierarchy (even `isHidden`) still holds an
  out-of-process WebKit drag registration at the window level, and — being in front of
  the drag search — intercepts a file drag aimed at the visible service, then refuses it,
  so the drop dies with no overlay. `MainViewController.select` `removeFromSuperview`s
  every inactive WebView (nil window ⇒ not a drag target) and re-adds it on switch-back.
  Don't restore the old "toggle `isHidden`, keep siblings mounted" scheme. (`NonNavigatingWebView.willOpenMenu` separately
  strips expensive context-menu items — Look Up / Share / AutoFill — that force synchronous
  Visual-Look-Up on the main thread and lag WhatsApp's media viewer.)

### Conventions
- `@MainActor` on the UI/WebKit types; AppKit and WebKit work stays on the main thread.
- The `userAgent` is forced to desktop Safari (`UserAgent.desktopSafari`) per WebView —
  required or WhatsApp Web shows "Browser not supported."
- Swift style: 4-space indent, `final class`, `private` implementation state, sparse comments
  reserved for non-obvious macOS/WebKit/signing/lifecycle behavior.

## Project workspace & history

- **`.spectacular/`** is the authoritative planning workspace — `SPEC.md` (capabilities),
  `ARCHITECTURE.md`, `DECISIONS.md` (e.g. WebK-over-WebZ for Telegram, UA rationale),
  `ROADMAP.md`, and per-feature request docs. Consult it before large changes.
- **`FEEDBACKS.md`** is a running log of observed rough edges with root-cause + fix notes —
  read it before touching upload, notifications, fonts, clipboard, or sleep behavior; many
  non-obvious WebKit constraints are already documented there.
- `AGENTS.md` holds contributor guidelines; `README.md` the user-facing overview.
