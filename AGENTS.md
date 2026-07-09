# Repository Guidelines

## Project Structure & Module Organization

Wasabi is a native macOS app written in Swift 6 with AppKit and WebKit. Primary source files live in `Sources/`; `main.swift` wires the AppKit entry point, `AppDelegate.swift` owns launch/window setup, and UI/webview behavior is split across files such as `MainViewController.swift`, `WebViewController.swift`, and `WebViewPool.swift`. 

### Key Modules and Code Organization

- **Entry Point & Layout**:
  - `main.swift`: Standard Swift entry point that boots the AppKit lifecycle.
  - `AppDelegate.swift`: Manages application startup, active window configuration, and programmatic menu construction.
  - `MainMenu.swift`: Programmatically constructs the application main menu. This is critical for keyboard shortcuts (⌘C, ⌘V, ⌘X, ⌘A, etc.) to travel down the responder chain to the focused webview.
  - `MainViewController.swift`: Primary layout controller. Manages the resizable sidebar, coordinates the list of services (including CRUD and reordering), renders the "Waking..." overlay, and manages Dock icon state.

- **Web Views & Pools**:
  - `WebViewController.swift`: Wraps a single `WKWebView` per service. Manages its lazy instantiation/teardown, page navigation policy, downloads, and delegate protocols.
  - `NonNavigatingWebView.swift`: Custom `WKWebView` subclass that cancels direct file URL navigation to allow web app DOM drag-and-drop. It also filters out expensive native context menu items (like Look Up and Share) to prevent main-thread UI lag.
  - `WebViewPool.swift`: Owns the sleep/wake lifecycle for all services. Manages the active service and monitors inactive services, applying their sleep policies (e.g. smart sleep or timer-based) to discard web views and release RAM.

- **Domain & Persistence**:
  - `Service.swift` / `SleepPolicy.swift` / `UserAgent.swift`: Core domain models representing service configurations, user-agent defaults, and RAM sleep modes.
  - `ServiceRegistry.swift`: The persisted source of truth (`UserDefaults`) for the user-managed service list, firing changes to trigger UI updates.
  - `DataStoreID.swift`: Generates a stable UUID per service, keying isolated persistent `WKWebsiteDataStore` instances.

- **Icons & Favicons**:
  - `FaviconProvider.swift`: Intercepts DOM favicon URLs, fetches them, and saves them to a local cache directory on disk to swap sidebar placeholders dynamically.
  - `AppIconRenderer.swift` / `AppIconStyle.swift`: Renders a dynamic Dock icon squircle showing a grid of the active services' favicons. The `AppIconController` monitors style changes and favicon resolutions to rebuild the composite icon.

- **WKWebView Bridges (Document Start Injection)**:
  - `NotificationBridge.swift` / `NotificationManager.swift`: Injects `window.Notification` shim and routes notifications to the native `UNUserNotificationCenter`.
  - `ClipboardBridge.swift`: Shims `navigator.clipboard` to macOS `NSPasteboard`.
  - `VisibilityBridge.swift`: Custom Page Visibility API shim, forcing background web views to pause timers and back off rendering when not focused.

- **Licensing & Updates**:
  - `LicenseBackend.swift` / `LemonSqueezyBackend.swift`: Defines validation behavior and implements client validation calls to Lemon Squeezy.
  - `LicenseManager.swift` / `LicenseWindow.swift`: Manages keychain-backed license keys, offline grace logic, and activation UI.
  - `UpdateChecker.swift`: Periodically checks for application updates.
  - `MenuItemSymbol.swift`: Helper extension to set SF Symbols on menu items.

- **Utilities & Other Paths**:
  - `DebugLog.swift`: Synchronous logging to `/tmp/wasabi.log` when `WASABI_DEBUG_LOG=1` is set in the environment.
  - `Sources/_swiftui_deferred/`: SwiftUI code parked for later, excluded from CLI compilation.
  - `Info.plist` / `Wasabi.entitlements`: App metadata and capabilities.
  - `Resources/`: App icons and static assets.
  - `scripts/`: Dev-only build, signing, and release scripts.
  - `project.yml`: XcodeGen source file.

Dev-only paths are compiled behind `#if WASABI_DEV` (set by `build-app.sh`, omitted by the author's release build), so a release build cannot ship the license bypass or stub backend.

## Build, Test, and Development Commands

- `scripts/build-app.sh`: compiles the AppKit/WebKit sources with `swiftc`, assembles `build/Wasabi.app`, copies the icon, and signs locally.
- `open build/Wasabi.app`: launches the locally built app after a successful script build.
- `WASABI_DEBUG_LOG=1 open build/Wasabi.app`: enables synchronous debug logging to `/tmp/wasabi.log`.
- `scripts/make-icns.sh`: regenerates `Resources/AppIcon.icns` from `scripts/make-icon.swift`.
- `scripts/make-signing-cert.sh`: creates the stable local signing identity used by the build script to reduce keychain prompts.
- `xcodegen generate`: regenerates `Wasabi.xcodeproj` from `project.yml` when XcodeGen is installed.

There is no committed automated test target. For now, verify changes by building and manually exercising the affected webview, menu, upload, icon, or sleep-policy behavior.

## Coding Style & Naming Conventions

Follow the existing Swift style: four-space indentation, `final class` for non-inherited classes, focused types, and explicit access control such as `private` for implementation state. Use UpperCamelCase for types (`MainViewController`) and lowerCamelCase for properties, methods, and enum cases. Keep comments sparse; add them only for non-obvious macOS, WebKit, signing, or lifecycle behavior.

## Testing Guidelines

When adding tests later, prefer an Xcode test target generated from `project.yml`. Name test files after the unit under test, for example `SleepPolicyTests.swift`, and keep webview-heavy behavior injectable where possible. Until then, include manual verification steps in PRs.

## Commit & Pull Request Guidelines

Recent history uses short conventional prefixes such as `feat:` and `fix:`, with merge commits naming the branch and release note when relevant. Keep commits focused, for example `fix: preserve webview focus after upload`.

PRs should describe the user-visible change, list manual verification, link related issues or Spectacular request docs when applicable, and include screenshots or recordings for visible UI changes.

## Security & Configuration Tips

Do not commit private signing identities, derived build products, or local keychain material. Keep entitlement changes minimal and explain why new macOS capabilities are required.

