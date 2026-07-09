# Privacy Policy

**Wasabi** — last updated 2026-07-03

## Short version

Wasabi has no servers, no analytics, and no telemetry. Nothing you do in the
app is sent to us, because there is no "us" to send it to. All your data stays
on your Mac.

## What Wasabi does

Wasabi is a native macOS shell that hosts web apps (such as WhatsApp Web and
Telegram Web), each in its own isolated system `WKWebView`. It is not a browser
and does not perform general web browsing.

## Data Wasabi stores — locally, on your Mac only

- **Login sessions, cookies, and site data** for each service are stored by
  Apple's WebKit in a per-service, on-disk data store under your macOS user
  Library (`~/Library/WebKit/…`). Each service is isolated from the others.
  This is the same mechanism Safari uses, managed by macOS — not by Wasabi.
- **Your service list and preferences** (which services you added, their order,
  sleep policies) are stored in the app's local `UserDefaults`.

Wasabi does not read, collect, transmit, or have any access to your messages,
contacts, media, or account credentials. Those are handled entirely by the
web services themselves, inside WebKit.

## Data Wasabi transmits

None to us. Wasabi makes network connections only to the web services you
choose to load (e.g. `web.whatsapp.com`, `web.telegram.org`), exactly as a
browser would when you visit those sites. Those connections go directly from
your Mac to those services and are governed by **their** privacy policies and
terms of service, not this one.

## Third-party services

The web services Wasabi displays (WhatsApp, Telegram, and any others you add)
are operated by their respective owners. Your use of them is subject to their
own privacy policies. Wasabi is an independent application and is not affiliated
with, endorsed by, or sponsored by those services.

## Permissions

Wasabi requests camera and microphone access only so hosted web apps can use
them for calls and voice messages. Access is mediated by macOS; you are prompted
by the system and can revoke it in System Settings at any time.

## Contact

Questions about this policy: support@gin.so
