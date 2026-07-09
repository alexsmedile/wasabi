# Feedbacks

Running log of observations and rough edges noticed while using Wasabi.
Lightweight capture — promote to a `.spectacular/` request or memory when acted on.

---

## 2026-05-29 — File upload broken (crash / opens PDF in view)

**Observed (IT):** "non funziona l'upload dei file, va in crash o apre il pdf in
view invece di inserirlo nel drop file" — file upload doesn't work: it either
crashes, or a dropped PDF opens in the web view instead of attaching.

**Cause:** two distinct defects, same root (missing WKWebView delegate wiring):
- The WebView had no `WKUIDelegate`, so clicking an `<input type=file>` had no
  open-panel to present — nothing happened, and an unanswered completion handler
  can crash the WebContent process.
- WKWebView's default drag destination navigates *to* a dropped file URL, so a
  PDF dropped on the chat opened the PDF (confirmed in /tmp/wasabi.log:
  `didFinish: file:///…/.pdf`) instead of reaching the page's JS drop zone.

**Fix:** added a `WKUIDelegate` implementing `runOpenPanelWith` (native NSOpenPanel,
honors `multiple`, always answers the completion handler); and a
`NonNavigatingWebView` subclass that strips file-URL types from the registered
drag types so file drops fall through to the page's DOM drop handler.

**Status:** fixed (2026-05-29) — user verified both the attach button and
drag-and-drop attach correctly. **Severity:** high (core messaging feature).

---

## 2026-05-29 — WhatsApp "background sync" popup crashes

**Observed (IT):** the WhatsApp "Turn on background sync" popup opened and the
app crashed immediately. Hypothesis from the popup wording: WhatsApp was really
asking for **notification permission**.

**Cause (confirmed):** the hypothesis was right. macOS public-API WKWebView has
*no* Web Notification support — no permission method in `WKUIDelegate`, no
`WKPreferences` flag (Safari uses private SPI). So `Notification.requestPermission()`
was never answered, hanging/crashing the WebContent process — the same
unanswered-handler class as the file-upload crash.

**Fix:** since native delivery is impossible, intercept. `NotificationBridge`
injects a `WKUserScript` at document start that patches `window.Notification`
(reports `granted`, resolves `requestPermission()` immediately → kills the
crash, forwards `new Notification(...)` to native via `WKScriptMessageHandler`).
`NotificationManager` re-emits through `UNUserNotificationCenter`.

**Status:** fixed + user-verified (2026-05-29) — popup grants cleanly, native
banner appears, sound plays. **Severity:** high (crash + core feature).
**Note:** no Xcode required — `UserNotifications.framework` ships in the CLT SDK.

---

## 2026-05-29 — Fonts render poorly

**Observed:** Text in the web views renders poorly — fonts look off (likely
fuzzy / thin / not crisp) compared to Safari or a native app.

**Likely causes to investigate:**
- WKWebView may not be getting the same font-smoothing / subpixel-antialiasing
  treatment as Safari. macOS turned off subpixel AA system-wide (since Mojave),
  so text relies on grayscale AA + Retina; a non-layer-backed or oddly-scaled
  view can look thin.
- Layer backing / `wantsLayer` + backing-scale: if the WebView's layer
  `contentsScale` doesn't match the screen (2.0 on Retina), glyphs render at 1x
  and look blurry.
- `-apple-system` font stack: web apps requesting system fonts should resolve to
  SF; verify the desktop-Safari UA isn't causing the site to ship a fallback
  webfont that renders worse.
- Window/View not pixel-aligned, or a CALayer with a fractional frame.

**Status:** RESOLVED / won't-fix (2026-07-06). The opaque-layer fix (`947e68a`,
2026-05-29) took it from medium to "better but not perfect"; nothing font-related
was touched since. Re-investigated 2026-07-06: we're already doing the Apple-correct
thing — `NSHighResolutionCapable = true` in Info.plist, content over `https://` (so
WKWebView propagates the display backing scale → `devicePixelRatio` = 2, no scaling
bug), no `pageZoom`/magnification meddling, global font smoothing (no per-app
override). The old "next step" (`layer.contentsScale = backingScaleFactor`) was a
**misdiagnosis**: on a WKWebView that controls WebKit's compositor scale, not the
CALayer's, and forcing it desyncs sub-pixel alignment (makes glyphs *worse*). The
only real lever left is the `_setOverrideDeviceScaleFactor` SPI — deliberately not
used (private API, and only needed for custom-URL-scheme content, which we don't
have). Residual softness is the user's **scaled 4K display mode** (`UI Looks like:
2304×1296`, a non-integer HiDPI scale where macOS renders at 2× then resamples) —
user confirmed it doesn't bother daily use. No code change warranted.
**Severity:** low → closed.

---

## 2026-05-29 — Keychain prompt still appears once after a rebuild

**Observed:** After rebuilding the app, the first launch still asks for keychain
permission once (user confirmed). Subsequent launches of the *same* build should
be silent.

**Cause:** Each rebuild changes the binary → new CDHash → macOS re-validates the
`WKWebsiteDataStore` keychain ACL and prompts once. Clicking "Always Allow"
authorizes that signature until the next rebuild. We removed `--options runtime`
and added `--entitlements` to keep the signing context stable, but a changed
CDHash inherently re-triggers the one-time prompt.

**Status:** acceptable for dev (only bites on rebuild, not daily reuse of a
shipped build). **To confirm:** reopen the same build twice → should be silent
on the second open. Revisit only if it prompts on repeat launches of an
unchanged binary.
**Severity:** low.

---

## 2026-05-29 — Keyboard copy/paste shortcuts don't work

**Observed (IT):** "non sta funzionando il copia e incolla con gli shortcut,
quando seleziono testo, solo tasto destro > copy" — selecting text and pressing
⌘C does nothing; only right-click → Copy works. Same for paste (⌘V).

**Cause:** the app installs **no main menu** (`NSApp.mainMenu` is nil — `main.swift`
is a pure-AppKit entry with no nib/storyboard). On macOS the standard editing
shortcuts (⌘X/⌘C/⌘V/⌘A) are owned by the **Edit menu**; the menu items carry the
key equivalents that dispatch `cut:`/`copy:`/`paste:`/`selectAll:` down the
responder chain to the focused WKWebView. With no Edit menu those keystrokes have
no target, so they're swallowed. Right-click works because that's WebKit's own
context menu, independent of the app menu.

**Fix:** install a minimal programmatic `NSMenu` with an App menu (Quit ⌘Q) and a
standard Edit menu (Undo/Redo, Cut/Copy/Paste/Select All with key equivalents).
Standard first-responder selectors route to the WebView automatically.

**Status:** fixed (2026-05-29).
**Severity:** medium (basic UX).

---

## 2026-05-29 — Sleep-on-switch is too aggressive (expected, M1 only)

**Observed:** With M1's proof mode (`sleepOnSwitch = true`), leaving a service
tears it down instantly, so returning always reloads (~2-4s). User: "sleep is
too aggressive right now (of course). It should sleep+wake in cycles."

**Status:** by design for M1 proof. Real behavior = per-service policy
(keep running / sleep after N min / smart adaptive cycling). Tracked in
`.spectacular/requests/sleep-policy-webviewpool/` M2–M4. Smart sleep is the
"cycles from sleep to wake" the user wants.
**Severity:** n/a — known, planned.

---

## 2026-07-04 — LicenseWindow crashes on close (double-release)

**Observed:** Clicking the ✕ on the freemium paywall / License window crashed the
whole app. Stack top was identical every time:
`objc_release → -[_NSWindowTransformAnimation dealloc]` inside a QuartzCore
transaction flush (`CA::Transaction::commit`) — EXC_BAD_ACCESS on freed memory.

**Cause:** a self-retained standalone `NSWindow` released **twice** on close. A
titled `NSWindow` defaults to `isReleasedWhenClosed = true`, so AppKit releases
the window itself as part of its close animation (`_NSWindowTransformAnimation`).
But `LicenseWindow` *also* owns the window via its `retain = self` / `let window`
lifetime. Two owners both releasing → double-free → crash in the animation's
dealloc. **Red herring:** the crash looks like a use-after-free of *our* object,
so the first two fix attempts moved *when* we cleared `retain` (sync → deferred
`DispatchQueue.main.async`). Neither helped — the extra release was always
AppKit's, not ours. `AddServiceSheet` never hit this because it's a **sheet**
(`beginSheet`/`endSheet`, no close animation, no `isReleasedWhenClosed` path).

**Fix:** `window.isReleasedWhenClosed = false` in `LicenseWindow.init` — AppKit no
longer releases the window on close, so the object's `retain` is the sole owner
and clearing it in `windowWillClose` is the only release. One line.

**Rule:** any standalone (non-sheet) `NSWindow` whose lifetime you manage with a
strong self-reference MUST set `isReleasedWhenClosed = false`, or AppKit's close
release collides with yours.

**Status:** fixed (2026-07-04).
**Severity:** high (crashed the app on a common action).
