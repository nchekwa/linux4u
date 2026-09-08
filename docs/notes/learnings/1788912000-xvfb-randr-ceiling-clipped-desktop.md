---
title: Xvfb RANDR ceiling clips the desktop with no error message
date: 2026-09-08
tags: [selkies, xvfb, xrandr, randr, resolution, hidpi, devops]
severity: medium
---

## Problem

Live Selkies VM: the desktop did not cover the browser viewport. The right edge
of the XFCE session fell outside the visible area, so the window buttons
(close / minimise / maximise) were unreachable. Nothing was logged — not by
Selkies, not by the browser console. The stream itself worked fine.

`xrandr` on the VM told the whole story:

```
Screen 0: minimum 1 x 1, current 1920 x 1080, maximum 1920 x 1080
screen connected primary 1920x1080+0+0 0mm x 0mm
   1920x1080      0.00*
  2888x1584 (0x22d) 297.750MHz +HSync -VSync
  2880x1580 (0x22e) 296.250MHz +HSync -VSync
  2080x1260 (0x25b) 174.000MHz +HSync -VSync
```

Three oversized modes present but **never attached** — listed without a refresh
rate, while `*` stayed on 1920x1080. One orphan per connect attempt from a
2880x1800 HiDPI client (which at default scaling asks for ~2880x1580).

`--enable_resize=true` was confirmed present in the running process, so resize
was not disabled. It was being *refused*.

## Root Cause

Xvfb allocates the framebuffer **once**, from `-screen 0 WxHx24`, and that
geometry becomes the RANDR `maximum` **permanently** — Xvfb has no dynamic
screen-memory reallocation, so `maximum` cannot be raised at runtime.

Selkies was behaving correctly the whole time:

1. client reports its viewport size
2. `xrandr --newmode` + `--addmode` → **succeeds** (`RRCreateMode` is happy)
3. `xrandr --output screen --mode 2880x1580` → **fails**, `BadMatch`, because
   2880 > `maximum` 1920
4. Selkies does not escalate step 3 to the client — it just stays at 1920x1080

The client then renders a 1920x1080 desktop inside a ~2880 px wide window and
the surplus falls outside the viewport. Hence: visual symptom, zero errors.

Two contributing factors:

- The image was built from an older copy of the builder (`tmp/debian_qcow2-cloud-init-selkies.sh`
  still had `SELKIES_RES:-1920x1080` and rendered the template with it), so the
  VM's ceiling was 1920x1080 even though the maintained builder had already
  moved to 2560x1440.
- 2560x1440 would **not** have fixed it either: 2880 > 2560. The default was
  sized for a "common" HiDPI laptop that did not include the actual hardware in
  use.

## Solution

Split the one conflated knob into two, since Xvfb merges them but only one can
change later:

- `SELKIES_MAX_RES` — the **ceiling** (`-screen` geometry → `maximum`), default
  raised to `3840x2160` so anything up to 4K just works.
- `SELKIES_RES` — the **starting mode**, default `1920x1080`, applied under that
  ceiling by `start-desktop.sh` after the X socket appears but **before**
  `startxfce4`, so XFCE lays its panels out for 1080p rather than the full
  framebuffer.

Xvfb boots the screen **at** the ceiling and advertises **only** the ceiling
mode, so the starting mode has to be created before it can be selected. Verified
against a real `Xvfb :77 -screen 0 3840x2160x24`:

```
current 1920 x 1080, maximum 3840 x 2160
   3840x2160      0.00
   1920x1080     28.94*
```

and the previously-refused client mode then attaches:

```
xrandr --output screen --mode 2880x1580   # RESIZE OK
current 2880 x 1580, maximum 3840 x 2160
```

Implementation notes:

- Modeline timings are **deliberately fake** (`W W W W  H H H H`, 60.00) and
  computed inline. There is no monitor and no pixel clock to respect, and doing
  it inline drops the `cvt(1)` dependency — an early version called `cvt` and
  failed silently on a host without it.
- `cvt` also names its mode `WxH_60.00`, **not** `WxH`, so code that shells out
  to it must read the emitted name back rather than assume `--addmode WxH`.
  Avoided entirely by not using `cvt`.
- The whole step is non-fatal (`|| true`, warning to stderr): a desktop sitting
  at the ceiling still works, and Selkies resizes on connect anyway. Confirmed
  the function survives `set -euo pipefail` when `xrandr` is missing or refuses.
- Short-circuited when `START_RES` equals `MAX_RES`.

Raising the ceiling costs **RAM only** — `W*H*4` bytes, ~33 MB at 4K. It costs
no bitrate and no CPU at smaller windows, because only the actual session
resolution is encoded, never the ceiling. Prefer a generous ceiling over
re-debugging a clipped desktop.

## Gotcha for next time

`bin/deskui` edits this file by regex. It was reading `^RES='...'`, which the
rename to `MAX_RES=` would have broken silently (the TUI would have shown an
empty "Resolution:" and its `sed` would have matched nothing). It now targets
`^MAX_RES=` and leaves `START_RES=` alone. **Any rename of a shell var in
`linux-debian/selkies/*.tpl` must be grepped against `bin/deskui`** — the
coupling is a regex, so nothing fails at build time.

Note the `^` anchor matters: an unanchored `RES=` pattern would match both
`MAX_RES=` and `START_RES=`. Verified the getter returns exactly one value and
the `sed` rewrites only the ceiling.

## References

- Screen ceiling / orphan-mode mechanics: [[1788480000-selkies-streaming-defaults-xvfb-randr]]
- `docs/notes/devops.md` → "Selkies image — streaming defaults"
- Files: `linux-debian/selkies/start-desktop.sh.tpl`,
  `linux-debian/debian_qcow2-cloud-init-selkies.sh`, `bin/deskui`
