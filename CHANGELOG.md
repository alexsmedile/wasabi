# Changelog

All notable changes are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)

---

## [Unreleased]

### Added
- **In-app update check is live.** `UpdateChecker` now reads a real manifest
  (`latest.json` served off the public releases repo) instead of a placeholder URL.
  On launch and via "Check for Updates…", the app compares the running build to the
  latest release and offers a download when a newer version ships. The manifest is
  regenerated automatically by the release pipeline, so every release is discoverable.

## [0.5.4-beta] — 2026-07-09

### Changed
- **Public launch — source is now open.** Wasabi's source repository is public at
  [github.com/alexsmedile/wasabi](https://github.com/alexsmedile/wasabi), with a
  rewritten README (UI mockup, feature overview, build-from-source instructions).
- **License → source-available (PolyForm Noncommercial 1.0.0).** Wasabi moves from
  proprietary/all-rights-reserved to the [PolyForm Noncommercial License 1.0.0](LICENSE):
  the source is public and free to read, build, modify, and use for any noncommercial
  purpose, while commercial use (selling, reselling, commercial redistribution) requires
  a separate license from the author. The paid notarized auto-updating build and Pro
  features remain author-distributed. Distribution strategy: open the repo for reach;
  monetize via the paid build + the existing `LicenseManager` Pro gate (Smart Sleep,
  unlimited services, reorder, custom icons — future plugins/themes additive).
- **Contributor terms (`CONTRIBUTING.md`).** Contributions now carry a DCO + a grant
  of commercial rights to the author, so outside code can be included in the paid/Pro
  build without breaking the dual-license model. Contributors retain their copyright.
- **Release tooling is vendor-internal.** Signing, notarization, and publishing the
  distributable build are handled by the author and are not part of the public source.
  The public build path is unchanged: `build-app.sh`, `make-signing-cert.sh`, and the
  icon + RAM scripts build and run Wasabi from source (unsigned, non-auto-updating,
  Pro-locked).

### Removed
- **Private planning kept out of the public repo.** Internal monetization specs,
  marketing, the launch playbook, and the `.spectacular/` workspace are gitignored;
  two example requests are kept to showcase the Spectacular workflow.

## [0.5.3-beta] — 2026-07-08

### Fixed
- **File drop dies after visiting another service.** After dragging a file onto one
  service (e.g. ChatGPT), dropping onto a different visible service did nothing — the
  drop overlay never appeared and the file never attached, for any file type. An
  inactive service's WebView stayed mounted in the window, and its out-of-process
  WebKit drag registration intercepted the drag aimed at the visible service, then
  refused it (hidden ⇒ no drop). Inactive WebViews are now removed from the view
  hierarchy entirely (nil window ⇒ not a drag target) and re-added on switch-back, so
  only the visible service can receive a drop.

## [0.5.2-beta] — 2026-07-06

### Added
- **Reload a service.** The active service reloads in place via ⌘R or View ▸ Reload,
  and any service reloads from its right-click menu (Back · Reload · Sleep now ·
  sleep modes). Reload preserves the session and data store — no re-login — and is
  disabled while a service is asleep (it cold-loads on the next wake anyway). Wasabi
  has no browser chrome, so this is the only in-place refresh for a stuck or stale
  web app short of a sleep/wake cold reload.

### Fixed
- **Cross-tab file drop.** After a service slept and woke, dragging a file onto the
  visible service could silently upload it into a *hidden* sibling instead: a stale
  WebKit drag registration on the mounted-but-hidden sibling let AppKit's drag search
  deliver the drop there. Hidden WebViews now refuse every drop, and slept WebViews
  are unmounted so they leave no stale drag destination behind.
- **Copy on ChatGPT.** ChatGPT's copy buttons and its ⌘C handler write a `text/plain`
  `ClipboardItem` via `navigator.clipboard.write()`, which the clipboard shim treated
  as an image and dropped — so ⌘C and the in-page copy icons put nothing on the
  clipboard (only right-click Copy worked). The shim now bridges `text/plain` text
  through to `NSPasteboard`.

## [0.5.1-beta] — 2026-07-03

### Added
- **Wake loader.** Selecting a slept service now shows a "Waking…" curtain (moon +
  an indeterminate spinner) over the blank cold-reloading WebView, fading out once
  the page paints. Masks the white loading flash and signals the reload is in
  progress instead of a frozen icon. A 0.5 s minimum hold keeps a fast warm-cache
  reload from flashing the spinner for a single frame.
- **Sleep now.** A service's right-click menu gains "Sleep now" — release its
  WebContent process immediately regardless of policy, to reclaim RAM on demand.
  Disabled for the active service and one already asleep.

### Changed
- **Smart Sleep grace is now focus-aware.** A just-left service was torn down after
  a flat 20 s regardless of whether you were still in the app — a message could
  land before you could reply. The grace now depends on app focus: 3 min while
  Wasabi is frontmost (you're still navigating other tabs), 60 s once you switch to
  another app. Leaving Wasabi mid-grace collapses any still-awake service onto the
  short window immediately.

### Fixed
- **Add-service dialog.** Pressing Return with an empty address no longer silently
  does nothing — it shows a hint and focuses the address field. Editing a service
  now commits name + URL in a single registry update (no double persist/reload, no
  transient half-applied state). Typing in the name field no longer re-runs URL
  validation.

## [0.5.0-beta] — 2026-07-03

### Added
- **Notarized distribution.** A real Developer ID release pipeline — sign with
  hardened runtime → notarize → staple → DMG — produces a Gatekeeper-clean
  `Wasabi.dmg` that opens on any Mac with no security warning. `LICENSE`
  (proprietary) and `PRIVACY.md` (no servers, no telemetry — everything stays in
  local WebKit storage) added.
- **Licensing gate (foundation).** Launch is gated on a license key stored in the
  Keychain, with offline grace so a flaky network never locks out a paid user. A
  vendor-agnostic `LicenseBackend` seam lets a real store adapter (Lemon Squeezy /
  Paddle) drop in later; a dev-only stub drives the flow today. Dev conveniences
  are compiled out of release builds, and a release build cannot compile until a
  real backend is wired — so a paid build can't be unlocked for free.
- **Update notifications.** A lightweight in-app check (`Check for Updates…`, plus
  a non-blocking launch check) reads a small JSON manifest and offers a Download
  when a newer version is available. No framework, no bloat.
- **SF Symbol icons in menus.** The right-click service menu and the main menu bar
  now show system icons next to items, matching modern macOS menus.

### Changed
- Sidebar right-click **"Remove Service…" renamed to "Remove…"** (with a trash
  icon) — clearer, and no longer misreads as "Remote."
- Info.plist gains `NSHumanReadableCopyright`; version metadata synced across the
  build script and `project.yml`.

### Fixed
- **Removed the hard divider line** between the glass sidebar and content area; the
  translucent sidebar and crisp-text backdrop are unchanged.

## [0.4.0-beta] — 2026-06-26

### Added
- **Three sidebar size modes — Wide / Medium / Compact** (View ▸ Sidebar Size),
  remembered across launches. Medium is the shipped default; Wide ≈ a Finder/Notes
  source list; Compact is −25%. Switching animates and never reloads a WebView.
- **Native full-height sidebar in Wide mode (Layout B).** The window goes
  `.fullSizeContentView` with a transparent titlebar so the sidebar runs under the
  titlebar and the window's own traffic lights sit inside the sidebar top — the
  lights stay system-owned, so display scaling and theming are automatic.
- **View ▸ Reset Window Size** — restore the default 1200×760 window (exits
  fullscreen first, then re-centers).
- **Reliable window drag in Wide mode** via a thin top drag strip (double-click to
  zoom) plus draggable sidebar empty areas, since the hidden titlebar leaves no
  native grab area over the content.

### Changed
- **Polished sidebar icons.** Favicons render at their natural rounded shape (no
  more boxed tiles); the active service is marked by a thin green ring with a gap.
- **Asleep services are dimmed.** A service whose WebContent process has been
  released (Smart Sleep) shows its icon at reduced opacity, so reclaimed-RAM state
  is visible at a glance; it returns to full opacity on wake.
- Default launch window size is now **1200×760** (was 1100×760).

## [0.3.1-beta] — 2026-06-25

### Changed
- **Hardened the add/edit URL validator.** Pasted addresses with internal
  whitespace or control characters are now rejected instead of being accepted
  into a host that silently fails to load, and a malformed host (a bare TLD like
  `.com`, a doubled dot, or a trailing/leading dot) is rejected while real hosts
  and IPs still pass.

### Fixed
- **Uppercase URL schemes are no longer rejected.** Typing `HTTP://example.com`
  (or any upper/mixed-case scheme) was silently treated as invalid because the
  scheme case wasn't normalized before the http→https check; it now works.

### Removed
- Internal dead code with no behavioral effect: an unused `ServiceRegistry.move`
  helper (reordering goes through `setOrder`), an unused `isAsleep` flag, and a
  redundant hand-written `Service` initializer (folded into a property default).
  The empty-name→host fallback is now shared by add and edit so they can't drift.

## [0.3.0-beta] — 2026-06-25

### Added
- **Add any web app, not just the built-ins.** The sidebar "+" is now live: enter
  a URL (a bare host like `app.slack.com` works — it's normalized to `https://`)
  and an optional name, and the service is added with its own isolated, persistent
  session. The icon is the site's favicon (a neutral globe until it resolves).
  Services are owned by a persisted registry (`ServiceRegistry`) seeded once from
  the built-in WhatsApp + Telegram, after which the saved list is authoritative —
  built-ins become ordinary entries you can reorder, rename, or remove.
- **Remove a service** (right-click → Remove Service…, with confirmation). This
  fully reclaims it: the WebContent process is released, the isolated
  `WKWebsiteDataStore` is deleted, its policy + data-store-mapping defaults keys
  are cleared, and its cached favicon is evicted — no leftover session on disk.
- **Edit a service** (right-click → Edit…) to rename it or change its URL. The
  service keeps its identity, so its login session and sleep policy are preserved;
  a changed host re-resolves the favicon.
- **Reorder services by dragging** their sidebar icons. The dragged icon lifts
  into a floating preview that follows the cursor while the others reflow around
  the gap; the order is persisted across launches. The "+" always stays last.

### Changed
- **Smart Sleep is now the default policy for every service** (new and existing),
  replacing the always-live default — the lever toward the low-RAM goal. A
  one-time migration flips the built-ins to Smart on first launch after this
  release; every later per-service policy pick you make is remembered and never
  re-clobbered.
- **Smart Sleep keeps a service live for a short grace period after you switch
  away** instead of tearing it down instantly. Flicking between services (or a
  quick glance elsewhere and back) no longer pays a full teardown + cold reload;
  switch back within the window and the service was never slept. After the grace
  elapses, the adaptive wake-and-sync cycle begins as before.

### Fixed
- **Drag-and-drop file upload no longer fails intermittently.** Dragging a file
  into a service often showed the page's drop overlay but never attached anything.
  The earlier fix stripped the file pasteboard types (`.fileURL` /
  `NSFilenamesPboardType`) from the WebView's registered drag types — but WebKit
  needs those types to populate the DOM drop event's `DataTransfer.files`, and it
  re-registers them on every WebContent-process relaunch (now frequent with the
  0.2.0 shared process pool + sleep/wake). The strip raced those relaunches,
  leaving the overlay visible but the file unreachable. The drop is now handled
  correctly: file drag types stay registered, and the unwanted *navigation* to a
  dropped `file://` URL (the "PDF opens in-view instead of attaching" case) is
  cancelled deterministically in the navigation policy delegate.

## [0.2.1-beta] — 2026-06-15

### Fixed
- **Image context menu no longer lags.** Right-clicking an image in a service's
  full-screen media viewer (e.g. WhatsApp Web) hung for seconds: WebKit's native
  menu populates "Look Up", "Share…", "AutoFill", and "Insert from iPhone" by
  synchronously extracting and analyzing the full-resolution image on the main
  thread. `NonNavigatingWebView` now overrides `willOpenMenu` to strip those
  expensive items (plus the "iFrames" debug entry) by their stable WebKit
  identifiers, collapsing leftover separators. WebKit skips the costly extraction
  for items it doesn't present, so the menu opens instantly. The useful items —
  Open in New Window, Download Image, Copy Image, Copy Link — remain.

## [0.2.0-beta] — 2026-06-13

### Changed
- **Inactive services back off.** Hidden-but-mounted WebViews kept ticking their
  timers and `requestAnimationFrame` even while you looked at another service
  (WebKit only auto-throttles on window occlusion, not for a hidden sibling
  view). A new `VisibilityBridge` drives the standard Page Visibility API so an
  inactive service reports `document.hidden` and pauses its own background work —
  the same signal a backgrounded browser tab gets — while staying mounted for
  instant switch-back (no remount cost, no regression to instant switching).
- **Shared WebKit process pool.** All services now share one `WKProcessPool` so
  WebKit can coordinate memory across the WebContent processes. Session isolation
  is unchanged — it lives in the per-service data store, not the pool.

---

## [0.1.9-alpha] — 2026-06-11

### Added
- **Microphone & camera access.** Web apps can now use mic/camera (voice
  messages, calls): Wasabi grants WKWebView's media-capture permission and ships
  the required `NSMicrophoneUsageDescription` / `NSCameraUsageDescription` so
  macOS prompts once instead of silently denying.
- **Native clipboard for web copy.** A `navigator.clipboard` shim
  (`ClipboardBridge`) routes `writeText` and image `write` to `NSPasteboard` —
  so WhatsApp's "Copy" yields real text/image data instead of a URL. Images are
  written as raw original-format bytes (PNG stays PNG).

### Fixed
- **Image selection no longer lags.** The file-drop fix had also stripped `.URL`
  from the WebView's drag types, disrupting WebKit's drag machinery on image
  selection; only file URLs are stripped now.

### Changed
- **Instant service switching.** The two default services keep running so
  switching no longer triggers a cold network reload; WebViews mount once and
  toggle visibility instead of remounting (no Auto Layout thrash per switch).
- **Less wasted work.** The dynamic Dock icon re-render is coalesced and skipped
  in static mode; favicons resolve once per session (no per-navigation refetch);
  debug file logging is gated behind `WASABI_DEBUG_LOG=1` (off, zero I/O, by
  default).

---

## [0.1.8-alpha] — 2026-06-02

### Fixed
- **Downloaded files no longer replace the active web app.** Main-frame file
  navigations now become native WebKit downloads saved to macOS Downloads,
  preventing PDFs and other attachments from trapping the service web view in a
  document viewer.
- **Sidebar service menus now include Back.** Right-clicking a service icon
  exposes a Back action above the sleep-policy controls.

---

## [0.1.6-alpha] — 2026-05-29

### Added
- **Native macOS notifications.** Hosted services now raise real macOS banners
  (with sound) through Notification Center. Notifications are grouped per service,
  carry the service name, and clicking one brings Wasabi forward and switches to
  the service it came from. A 30-second dedup window prevents the same message
  from banner­ing twice on reload/reconnect.

### Fixed
- **WhatsApp "Turn on background sync" popup no longer crashes.** The popup was
  WhatsApp asking for notification permission; macOS WKWebView has no Web
  Notification support, so the request went unanswered and crashed the WebContent
  process. Wasabi now answers it (and delivers notifications natively — see above).

### Changed
- Sleep policy stays strictly stronger than notifications: a slept service
  receives none, and notifications never keep a service alive. Build now links
  `UserNotifications` (ships in the Command Line Tools SDK — no Xcode required).

---

## [0.1.5-alpha] — 2026-05-29

### Changed
- Dynamic app icon restyled: service favicons now sit in frosted translucent
  tiles that fill the squircle like fluid (outer corners hug the rim), over a
  translucent wasabi-green backdrop finished with a light-catching glass rim.

### Added
- `scripts/preview-icon.swift` — renders the dynamic icon to PNGs for inspection
  without launching the app.

---

## [0.1.4-alpha] — 2026-05-29

### Fixed
- **File upload now works.** Two defects fixed: (1) added a `WKUIDelegate` so
  clicking an attach button (`<input type=file>`) opens the native file picker —
  previously it did nothing or crashed the WebContent process; (2) dropping a
  file onto a chat now attaches it instead of opening it in the web view — a
  `NonNavigatingWebView` subclass keeps file URLs out of the web view's drag
  types so the drop reaches the web app's own drop zone.

### Added
- **Dynamic app icon.** `View ▸ App Icon` lets you choose between _Static (Wasabi)_
  — the bundled mark — and _Dynamic (Site favicons)_, which composites the added
  services' favicons onto a frosted-glass squircle in an adaptive grid (1 big,
  2 side-by-side, 3 as 2-over-1, 4 as 2×2, 5+ as first 3 + a "+N" tile). The
  dynamic icon rebuilds as favicons resolve and the choice persists across launches.

---

## [0.1.3-alpha] — 2026-05-29

### Added
- **Real site favicons in the sidebar.** Each service's icon is now resolved live
  from its WebView (best `apple-touch-icon`/`rel=icon`/`favicon.ico`), fetched,
  and cached to disk — no bundled assets. The SF Symbol stays as an instant
  placeholder and offline fallback; cached favicons appear immediately on relaunch.

### Changed
- Sidebar is 20% slimmer (60 → 48pt; icon buttons 44 → 36). Active/inactive icons
  are now distinguished by alpha as well as tint (favicons are bitmaps, not
  tintable template symbols).

### Fixed
- Keyboard copy/paste/cut/select-all (⌘C/⌘V/⌘X/⌘A) now work in the web views.
  The app had no main menu, so these shortcuts had no target in the responder
  chain and were swallowed — only right-click → Copy worked. Added a minimal
  programmatic main menu (App + Edit) that wires the standard editing shortcuts.

---

## [0.1.2-alpha] — 2026-05-29

### Added
- **Per-service sleep policy** (the low-RAM lever). Inactive services can be torn
  down to release their WebKit content process, reclaiming the full per-service
  heap (e.g. WhatsApp ~750MB → 0). Waking reloads from the persistent data store
  with no QR rescan. One active + one slept service measures ~300MB vs ~1GB
  both-live.
- Three policies, set via **right-click on a sidebar icon**, persisted per service:
  - _Keep running_ — never sleeps.
  - _Sleep after 5 min_ — **new default**: stays live 5 min after you switch away,
    then tears down if not refocused.
  - _Smart sleep_ — sleeps, then periodically wakes to sync and sleeps again, on
    an adaptive interval (~1 min when recent → ~5 min → ~15 min as idle grows).
- `WebViewPool` policy engine (timers + adaptive smart-sleep scheduler) and
  `WebViewController.sleep()` / `wake()` lifecycle.

### Changed
- Default per-service policy is now _Sleep after 5 min_ (was always-live).

### Fixed
- Improved WKWebView font rendering: opaque white layer on the WebView and its
  container so text antialiasing composites against a solid background.
- Build signs with explicit entitlements and drops Hardened Runtime for a stable
  local signing context (`scripts/build-app.sh`).

## [0.1.1-alpha] — 2026-05-29

### Fixed
- Eliminated the keychain password prompt that appeared on every launch. The app
  now signs with a stable self-signed "Wasabi Dev" identity instead of an ad-hoc
  signature, keeping the `WKWebsiteDataStore` keychain ACL matched across launches
  and rebuilds. Sessions and logins are preserved.

### Added
- `scripts/make-signing-cert.sh` — creates the stable signing identity once
  (OpenSSL-3-compatible legacy p12, signs by hash, no sudo / system-trust needed).
- `scripts/build-app.sh` now auto-signs with the stable identity when present,
  falling back to ad-hoc otherwise.

## [0.1.0-alpha] — 2026-05-29

### Added
- Initial Wasabi scaffold: native macOS AppKit + WebKit shell hosting WhatsApp Web
  and Telegram (WebK) behind a vertical service sidebar.
- Per-service persistent, isolated `WKWebsiteDataStore` — logins survive relaunch.
- Desktop-Safari `customUserAgent` to clear WhatsApp Web's browser-support wall.
- Command-Line-Tools build path (`scripts/build-app.sh`, swiftc) — no Xcode required.
- Kawaii wasabi mesh-gradient app icon (`scripts/make-icon.swift`, regenerable).
