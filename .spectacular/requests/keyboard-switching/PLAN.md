---
status: planned
priority: medium
updated: 2026-06-26
summary: "⌘1…⌘9 jump to the Nth service; ⌘[ / ⌘] (or ⌃Tab) cycle prev/next. The single biggest daily-driver ergonomics win for an app you live in, in ~20 lines reusing the existing select(serviceID:)."
---

# keyboard-switching — ⌘-number service switching

## Why

Wasabi is a chat app you keep open all day; reaching for the mouse to switch
services is the highest-frequency papercut. Every browser and chat client has
⌘1…⌘9. It was parked in the Icebox as "nice to have" but it's ~20 lines and
high-frequency, so it's worth doing now.

## How (the lazy path)

The machinery already exists: `MainViewController` has an ordered `services` array
and `select(serviceID:)`. This is purely a **menu + responder** addition, no new
state.

- Add a **Services** (or **Window**) menu, or extend the existing View menu, with
  items `1`…`9` carrying key equivalents ⌘1…⌘9, action
  `#selector(MainViewController.selectServiceByIndex(_:))`, `tag = index`.
  Native `keyEquivalent` on `NSMenuItem` — no event monitor, no custom key
  handling (which would fight the WebView's first-responder). ponytail: menu items
  are the macOS-native way; an `NSEvent` monitor is the wrong rung.
- `selectServiceByIndex(_:)` — `guard index < services.count`, `select(serviceID:
  services[index].id)`. ⌘9 maps to the **last** service (the macOS tab convention),
  not literally index 9.
- Optional cycle: ⌘] / ⌘[ (or ⌃Tab / ⌃⇧Tab) for next/prev, wrapping. One more
  selector doing `(activeIndex ± 1) mod count`.
- Rebuild/refresh the numbered items in `reloadServices()` so add/remove/reorder
  keeps the numbering in sync with the sidebar order.

## Scope (out)

- Per-service *user-customizable* shortcuts (YAGNI — fixed ⌘N is the convention).
- A global system-wide hotkey (that's a different feature; needs accessibility/SPI).

## Exit criteria

- [ ] ⌘1…⌘8 select the 1st–8th service; ⌘9 selects the last; no-op past the count.
- [ ] Shortcuts work while a WebView has focus (menu key-equivalents route correctly).
- [ ] Numbering follows sidebar order after add/remove/reorder.
- [ ] (If included) ⌘] / ⌘[ cycle next/prev with wraparound.
- [ ] Build clean + signed; manual verify across all three sidebar sizes.
