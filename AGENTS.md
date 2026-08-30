# AGENTS.md

## Stack
- Swift 6, AppKit + WebKit, macOS 15+ arm64 only. `main.swift` → `AppDelegate` → `MainViewController`. No nib/storyboard, no SwiftUI in the build — `Sources/_swiftui_deferred/` is excluded (`find -maxdepth 1` in `scripts/build-app.sh:22`, `project.yml:22` excludes).
- `project.yml` + `xcodegen generate` is an alternate Xcode path; the `swiftc` script is primary. `Wasabi.xcodeproj/` is gitignored — regenerate, don't commit.

## Commands
```sh
scripts/build-app.sh                    # swiftc → build/Wasabi.app + sign (primary build, CLT only, no Xcode)
WASABI_RELEASE=1 scripts/build-app.sh   # release build: strips WASABI_DEV, uses LemonSqueezyBackend (dev stub rejects real keys)
WASABI_DEBUG_LOG=1 open build/Wasabi.app  # sync log to /tmp/wasabi.log (off by default, see Sources/DebugLog.swift)
open build/Wasabi.app
scripts/make-signing-cert.sh            # one-time: create stable "Wasabi Dev" identity (reduces keychain prompts)
scripts/make-icns.sh                    # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
scripts/measure-ram.sh [-n 20 -i 3]     # phys_footprint soak via footprint + lsappinfo; don't use RSS
```
- Build flags: `swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macos15.0` (`scripts/build-app.sh:37`). `WASABI_DEV` (`-D WASABI_DEV`) is dev-only; `WASABI_RELEASE=1` compiles it out so bypass code doesn't ship. `WASABI_CHECKOUT_URL` and `WASABI_PRO_INFO_URL` are injected into `Info.plist` at build time; they are empty in public source builds.
- No test target, no CI workflows, no linter/formatter. Verify by building and manually exercising the affected path (webview, menu, upload, notifications, sleep/wake, license). Note manual steps in PRs.
- Signing: `security find-identity` **without** `-v`/`-p codesigning` (`scripts/build-app.sh:104`) — `-v` hides the untrusted self-signed fallback. Prefers `Apple Development` cert, falls back to `Wasabi Dev`, then ad-hoc. `--options runtime` (Hardened Runtime) deliberately omitted — it re-triggers keychain prompts for `WKWebsiteDataStore` with no benefit for local distribution. New CDHash still prompts once per rebuild — expected.

## Architecture — what agents get wrong
- **No storyboard ⇒ no Edit menu by default.** `MainMenu.build()` (called from `AppDelegate`) must install App + Edit menus or ⌘C/⌘V/⌘X/⌘A are swallowed (responder chain has no target). Right-click still works — that's WebKit's menu, not the app menu.
- **ServiceRegistry is the source of truth** (`UserDefaults` `wasabi.services.v1`, `Sources/ServiceRegistry.swift`), seeded once from `Service.defaults` (`Sources/Service.swift`). Mutations (add/remove/rename/reorder) fire `onChange`; `MainViewController` incrementally applies via `reloadServices()`. Per-service `SleepPolicy` persisted as `wasabi.sleeppolicy.<id>` (`Sources/SleepPolicy.swift`, `Sources/WebViewPool.swift`).
- **Isolation lives in the data store, not the helper-process count.** `WKWebsiteDataStore(forIdentifier: DataStoreID.uuid(for: service.id))` (`Sources/DataStoreID.swift`) isolates sessions. Wasabi does not assign custom process pools; WebKit owns helper allocation and may use multiple WebContent processes for one view, so PID count is not live-service count.
- **Sleep = teardown.** `WebViewPool` keeps one service `active` (always live); inactive services follow their `SleepPolicy` (keepRunning / autoSleepTimer / smartSleep). `WebViewController.sleep()` destroys the `WKWebView` to reclaim RAM; `wake()` rebuilds from the persistent store. Keep Running provides the best chance of instant notifications with higher RAM use. Sleep after 5 minutes pauses notifications once asleep. Smart Sleep wakes at a 5/15/60-minute cadence only while Wasabi is active; it is periodic refresh, not reliable push.
- **Bridges inject at document start.** `NotificationBridge`+`NotificationManager`, `ClipboardBridge`, and `VisibilityBridge` (`Sources/*Bridge.swift`) add `WKUserScript`s at `.atDocumentStart` in `WebViewController.makeWebView()` and are rebuilt on every wake. Notifications exist only while a WebView exists. Exact repeats are deduped for 30 seconds by service + tag + title + body; never reduce this to tag alone because chat apps reuse tags.
- **Drag-drop, picker uploads, and downloads are separate mechanisms.** `<input type=file>` needs `WKUIDelegate.runOpenPanelWith` → `NSOpenPanel`; mirror `allowsMultipleSelection` and `allowsDirectories`, but WebKit exposes no `accept` filter on macOS. File drop must **not** strip `fileURL` drag types—WebKit needs them for `DataTransfer.files`; cancel main-frame `file://` navigation instead. Downloads default to `~/Downloads`, sanitize/deduplicate filenames, retain each `WKDownload`, and track its destination until completion. Inactive WebViews must be removed from their superview so they cannot intercept drops.
- **Standalone windows:** any `NSWindow` you retain (`retain = self`) must set `isReleasedWhenClosed = false` (`Sources/LicenseWindow.swift`) or AppKit's close animation double-frees it. Sheets (`AddServiceSheet`) don't need this.
- **Icons:** `FaviconProvider` caches favicons to disk; `AppIconRenderer`/`AppIconController` composes the dynamic Dock squircle. Don't bundle favicons.

## Conventions
- 4-space indent, `final class`, `@MainActor` on UI/WebKit types, `private` impl state. Comments only for non-obvious macOS/WebKit/signing/lifecycle. Force `UserAgent.desktopSafari` per WebView or WhatsApp shows "Browser not supported" (`Sources/UserAgent.swift`).
- Commits: short conventional prefix (`fix:`, `feat:`). PRs: user-visible change + manual verification + screenshots for UI.
- Entitlements: `com.apple.security.app-sandbox = false` (`Sources/Wasabi.entitlements`); keep minimal, justify new capabilities. Don't commit `build/`, signing identities, or keychain material.
- Deeper context: `CLAUDE.md` (full architecture + gotchas), `FEEDBACKS.md` (upload/notification/clipboard/sleep bug history), `.spectacular/requests/` (planning workspace, mostly gitignored).

## Release discipline
- Align the release version/build in `project.yml`, `scripts/build-app.sh`, the README badge, and `CHANGELOG.md`; regenerate the ignored Xcode project with `xcodegen generate`.
- Run both `scripts/build-app.sh` and `WASABI_RELEASE=1 scripts/build-app.sh`, then verify the bundle metadata and signature. Release commits must be DCO-signed and tagged `vX.Y.Z-beta` only after the bounded diff and staged secret scan pass.
- Official Developer ID signing, notarization, stapling, DMG creation, and publication use vendor-only gitignored tooling. Public source agents must not commit credentials or claim a distributable release passed unless the app and DMG both validate and Gatekeeper accepts them.
