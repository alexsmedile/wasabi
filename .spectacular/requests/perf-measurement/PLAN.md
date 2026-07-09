---
status: in-progress
priority: high
updated: 2026-06-26
summary: "Make the headline RAM claim measurable and honest: a repeatable footprint script, baseline numbers for active vs asleep, and a verdict on what's actually improvable (spoiler: the active WhatsApp DOM is a WebKit/WhatsApp floor; the win is the asleep teardown)."
---

# perf-measurement — verify the RAM claims

## Why

Every comparison in the README/PRD rests on "<500 MB idle / <250 MB asleep, far
under Electron's 2–5 GB." That was an assertion. This request turns it into
measured fact, and decides whether the active-state number can be improved or is
a floor we should just document.

## Baseline (measured 2026-06-26, `scripts/measure-ram.sh`)

WhatsApp + Telegram both live, WhatsApp active, no other WebKit app running.
phys_footprint (the real cost, not RSS):

| Component | MB |
|---|---|
| Wasabi UI (AppKit) | 71 |
| WhatsApp WebContent | ~1100–1260 |
| Telegram WebContent | 59 |
| WebKit GPU helper | 135 |
| WebKit Networking helper | 62 |
| **TOTAL** | **~1.6 GB** |

**The finding:** the native shell is 71 MB. Telegram in the same engine is 59 MB.
WhatsApp's WebContent is ~20× heavier — that is WhatsApp's own React/DOM/media
footprint, not anything Wasabi controls. The owner's intuition ("the WhatsApp DOM
is just heavy as f") is confirmed by direct measurement.

## What's actually improvable

- ❌ **Active WhatsApp (~1.3 GB):** a WhatsApp+WebKit floor. We don't own their DOM.
  Don't chase it; document it.
- ✅ **The asleep floor — MEASURED 2026-07-08 (perf/optimization branch):** teardown
  is **complete, no leak.** Sleeping WhatsApp via the real `sleepNow → sleep()` path
  (had to switch away first — `sleepNow` is a no-op on the active service, by design)
  fully exited its WebContent process: pid at **800 MB → gone**, never relaunched,
  the OS reclaimed the entire footprint. So lever #1 in `../perf-optimization/` is a
  **no-op** — there is no teardown defect to fix. The ~330 MB target is reachable;
  the reason everyday RAM sits higher is *policy* (heavy service kept awake), not a
  teardown leak — that's lever #2's problem, not this one's.
- ➖ **Helpers (GPU 135 + Networking 62):** shared, already lean; not worth chasing.
  (Note: GPU helper footprint moves with the active service — observed 26 MB idle
  → 160 MB right after a service switch — so read helper numbers in a settled state.)

## Scope (in)

- `scripts/measure-ram.sh` — repeatable phys_footprint snapshot + soak (`-n`/`-i`),
  attributing WebKit helpers to Wasabi via `lsappinfo` (no sudo). **Done.**
- Capture three baselines into this doc / a `RESULTS.md`:
  1. **Active** (both live, heavy service focused) — done above.
  2. **Asleep floor** (heavy service slept via Smart Sleep) — verify it drops to ~330 MB.
  3. **Soak** (1h+, both live) — confirm no runaway growth.
- Update README/PRD to state the honest split: active cost is a documented WhatsApp
  floor; the <500 MB target applies to the **asleep/idle** state and is met there.

## Scope (out)

- WhatsApp DOM optimization (not ours to do).
- Cold-launch timing (separate concern; fold into a later perf pass if wanted).
- **Any tuning or teardown *fixing*.** This request only *measures*. If the asleep
  floor comes out wrong (the WebContent process doesn't fully exit, RAM doesn't
  drop to ~330 MB), that's a defect for `../perf-optimization/` to fix — record
  the number here, hand the fix there. Measure-owns-measuring; opt-owns-fixing.

## Exit criteria

- [x] `measure-ram.sh` gives correct, repeatable, sudo-free per-service numbers.
- [x] Asleep floor **measured** (2026-07-08, perf/optimization). Full teardown
      confirmed: a live 800 MB WhatsApp WebContent process fully exits on `sleep()`
      and the RAM returns to the OS — no leak. No fix needed in `../perf-optimization/`
      (lever #1 is a no-op). The everyday-RAM gap is *policy* (heavy service kept
      awake), handed to lever #2.
- [ ] 1h soak shows no growth past the active baseline.
- [ ] README/PRD wording reconciled to the measured reality (active floor documented,
      idle/asleep target shown as met or the honest WebKit floor stated).
