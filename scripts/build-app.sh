#!/usr/bin/env bash
# Build Wasabi.app with Command Line Tools only (no Xcode, no macOS 26).
# Compiles the AppKit + WebKit sources with swiftc and assembles a .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Wasabi"
BUNDLE_ID="app.wasabi.Wasabi"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOSX="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$MACOSX" "$RES"

# Compile every backend + AppKit source (exclude the parked SwiftUI shell).
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources" -maxdepth 1 -name '*.swift' | sort)

# Dev-only compilation flag. `-D WASABI_DEV` compiles in the license dev-bypass
# and any other #if WASABI_DEV conveniences. RELEASE builds must NOT define it, so
# those code paths physically don't exist in a shipped binary (not just runtime-
# rejected). The author's release build sets WASABI_RELEASE=1 to force a clean,
# flag-free build.
DEV_FLAG=(-D WASABI_DEV)
if [ "${WASABI_RELEASE:-0}" = "1" ]; then
    DEV_FLAG=()
    echo "==> RELEASE build — WASABI_DEV bypasses compiled OUT"
fi

echo "==> Compiling ${#SOURCES[@]} source files"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macos15.0 \
    -framework AppKit \
    -framework WebKit \
    -framework UserNotifications \
    ${DEV_FLAG[@]+"${DEV_FLAG[@]}"} \
    -O \
    -o "$MACOSX/$APP_NAME" \
    "${SOURCES[@]}"

echo "==> Bundling app icon"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
else
    echo "    (Resources/AppIcon.icns missing — run scripts/make-icns.sh)"
fi

# Pro checkout URL is injected here, not baked into source — the public repo
# carries no store URL. Empty (source builds) ⇒ the app's Buy button stays disabled.
CHECKOUT_URL="${WASABI_CHECKOUT_URL:-}"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.5.3-beta</string>
    <key>CFBundleVersion</key><string>9</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Alessandro Smedile</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSMicrophoneUsageDescription</key><string>Wasabi needs microphone access so web apps (e.g. voice messages, calls) can use it.</string>
    <key>NSCameraUsageDescription</key><string>Wasabi needs camera access so web apps (e.g. video calls) can use it.</string>
    <key>WASABICheckoutURL</key><string>$CHECKOUT_URL</string>
</dict>
</plist>
PLIST

# Sign with a STABLE self-signed identity if available, else fall back to ad-hoc.
# A stable identity keeps the keychain ACL for the WKWebsiteDataStore encryption
# key consistent across launches — otherwise macOS re-prompts for the password
# on every open.
#
# Identity preference (first that exists wins):
#   1. "Apple Development" — the real, Apple-TRUSTED dev cert from the Developer
#      Program. Trusted + stable, so macOS chains-validates every rebuild and the
#      keychain password prompt stops for good. Preferred now that it exists.
#   2. "Wasabi Dev" — the legacy self-signed local cert (make-signing-cert.sh).
#      Stable but UNtrusted (CSSMERR_TP_NOT_TRUSTED), so it re-prompts once per
#      rebuild. Fallback for a machine without the Apple cert.
#   3. ad-hoc — no stable identity; prompts most.
# We look up by SHA-1 hash via `find-identity` WITHOUT -v: -v filters to certs
# valid for the default policy, which would hide the untrusted self-signed
# fallback. The unfiltered list includes both, with the hash codesign needs.
ENTITLEMENTS="$ROOT/Sources/Wasabi.entitlements"
find_sign_hash() { security find-identity 2>/dev/null | grep "$1" | grep -oE '[0-9A-F]{40}' | head -1; }
SIGN_ID="Apple Development"
SIGN_HASH="$(find_sign_hash "$SIGN_ID")"
if [ -z "$SIGN_HASH" ]; then
    SIGN_ID="Wasabi Dev"
    SIGN_HASH="$(find_sign_hash "$SIGN_ID")"
fi
if [ -n "$SIGN_HASH" ]; then
    echo "==> Code signing with stable identity '$SIGN_ID' ($SIGN_HASH)"
    # Sign with explicit entitlements so the signing context is COMPLETE and
    # stable across rebuilds. We deliberately drop --options runtime: Hardened
    # Runtime tightens the keychain ACL check on the WKWebsiteDataStore key, and
    # since this is local-only self-signed distribution (no notarization), it
    # buys nothing while re-triggering the password prompt after a clean rebuild.
    ENT_FLAG=()
    [ -f "$ENTITLEMENTS" ] && ENT_FLAG=(--entitlements "$ENTITLEMENTS")
    codesign --force --sign "$SIGN_HASH" --identifier "$BUNDLE_ID" \
        "${ENT_FLAG[@]}" "$APP" 2>/dev/null && echo "    signed ✓" || {
            echo "    (signing failed — falling back to ad-hoc)"
            codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>/dev/null
        }
else
    echo "==> Ad-hoc code signing (run scripts/make-signing-cert.sh to stop keychain prompts)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>/dev/null || \
        echo "    (codesign skipped — app will still run)"
fi

echo "==> Built: $APP"
