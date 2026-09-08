---
title: Selkies streams nothing — missing libva breaks the pixelflux import
date: 2026-09-08
tags: [selkies, pixelflux, libva, ffmpeg, manylinux, libguestfs, elf, smoke-test]
severity: high
---

## Problem

The image built by `debian_qcow2-cloud-init-selkies.sh` at commit `1572c93`
looked completely healthy and rendered **no video at all**:

- all three services `active`, `systemctl --failed` empty
- HTTPS on :8080 returned **200**, basic auth worked, the web UI loaded
- keyboard, mouse, four virtual gamepads, cursor, WebSocket — all working
- **the browser sat on "Waiting for stream" forever**

The build itself succeeded end to end. Nothing in it failed.

## Root Cause

`pixelflux` — the Selkies 2.x screen-capture engine — could not be imported:

```
ImportError: libva-drm.so.2: cannot open shared object file: No such file or directory
```

The `pixelflux` manylinux wheel **bundles** ffmpeg and x264 under
`pixelflux.libs/` (RPATH `$ORIGIN/pixelflux.libs`) but deliberately does **not**
bundle `libva` — hardware drivers must match the host, so no manylinux wheel
ships them. Its bundled `libavutil`, `libavcodec` and `libavfilter` are built
**with VA-API**, so `libva.so.2`, `libva-drm.so.2` and `libva-x11.so.2` are
resolved **unconditionally at dlopen time, before any encoder is selected**.

The trap: **a linker dependency is not a functional one.** All of these were
true and none of them mattered —

- the VM has no GPU (`No GPUs detected`)
- the encoder is `h264enc`, pure software x264
- the script header says "no hardware video encoder available"

The builder installed only `libxkbcommon0` and `libpulse0`, assuming that if
hardware acceleration is unused, hardware-acceleration libraries are unneeded.
That assumption is wrong at the ELF level.

### Why it was so hard to see

Selkies logs the cause **once**, at startup, as a `WARNING`, buried among dozens
of gamepad `INFO` lines emitted the same second:

```
WARNING:data_websocket:pixelflux library unavailable
  (libva-drm.so.2: cannot open shared object file...). Striped encoding modes unavailable.
```

Then, on every client connect, it reports only the **effect**, with the cause
replaced by a pointer to a message that has long scrolled away:

```
ERROR:data_websocket:Failed to start capture for display 'primary'...
  Error: Cannot start capture: the pixelflux library failed to import
         (see the startup warning for the underlying error).
```

`journalctl -n 50` after the fact therefore shows a symptom with no cause, which
is why this reads as "selkies does not start" (it does) rather than "a package
is missing".

### Why pre-commit testing missed it

The import was verified **on the build host, which already had libva installed**
— not inside the image. A clean image is the only environment where this
reproduces. This is the whole lesson: `build success != image works`.

## Solution

Install the complete unbundled `NEEDED` set. Derived with `objdump -p` over the
main `.so` **and every bundled lib** in both wheels, not guessed:

| SONAME | Package | Needed by |
|---|---|---|
| `libva.so.2`, `libva-drm.so.2`, `libva-x11.so.2` | `libva2`, `libva-drm2`, `libva-x11-2` | pixelflux's bundled libav* |
| `libgbm.so.1`, `libdrm.so.2`, `libpixman-1.so.0` | `libgbm1`, `libdrm2`, `libpixman-1-0` | pixelflux main `.so` |
| `libICE.so.6`, `libSM.so.6`, `libXext.so.6` | `libice6`, `libsm6`, `libxext6` | pcmflux |
| `libxkbcommon.so.0` | `libxkbcommon0` | ctypes in `input_handler.py` |

Installed via `--run-command 'apt-get install -y --no-install-recommends ...'`
rather than `virt-customize --install`, because the latter always installs
Recommends and `libva-drm2` Recommends `va-driver-all` → `mesa-va-drivers` +
`i965-va-driver` + `intel-media-va-driver`, ~19.5 MB of GPU drivers that are
dead weight on a headless VM.

`pcmflux` bundles its own `libpulse`; the system `libpulse0` is still needed by
the Python-side `pulsectl`.

### The actual fix: a smoke test inside the image

The package list is the symptom fix. The regression guard is a build-time check
that runs **in the guest** and fails the build:

1. `ldd` sweep over every `*.so*` in `/opt/selkies/venv`, grepping for
   `not found`. This catches **any** unbundled library, including ones a future
   `pixelflux`/`pcmflux` bump introduces — not just the ones known today. It
   must cover `*.so*` (not `*.so`) so versioned bundled libs like
   `libavcodec-eb05b5f8.so.62.28.100` are inspected; those are the files that
   actually carry the `libva` NEEDED entries.
2. `import pixelflux, pcmflux, selkies` — catches breakage `ldd` cannot see.

Verified: the sweep inspects all 7 bundled pixelflux libs, three of which
(`libavutil`, `libavcodec`, `libavfilter`) carry the `libva` dependency.

## Two other defects found in the same report

**PulseAudio was locked inside `if [ "$DESKTOP_USER" = "root" ]`.** The default
image (`DESKTOP_USER=user`) shipped with no audio server at all, while
`libpulse0` was installed unconditionally — client present, server absent. Every
connect looped a `pulsectl` stack trace. The fix had been scoped to the
condition it was *debugged under* rather than to its *cause*. Now
unconditional, with `usermod -aG pulse-access ${DESKTOP_USER}`.

Ask on every fix: *is the condition I am putting this under the cause of the
problem, or just the circumstance in which I noticed it?*

**`XDG_RUNTIME_DIR` fell back to `/tmp`.** `/tmp` is root-owned `1777`, and
PulseAudio correctly refuses a runtime dir it does not own
(`XDG_RUNTIME_DIR (/tmp) is not owned by us, but by uid 0`). The fallback turned
a clear "no runtime dir" condition into a misleading "connection refused". These
units have no `PAMName=login`, so logind never creates `/run/user/<uid>`; the
fallback is now `/run/selkies`, which `xfce-session.service` creates via
`RuntimeDirectory=selkies` (`Preserve=yes`) owned by the desktop user.

**A stale comment made diagnosis worse.** The script claimed "Selkies' audio
pipeline is MANDATORY (its failure aborts the video stream, leaving the browser
on 'Waiting for stream')". True for 1.x/WebRTC (one GstPipeline for both paths),
**false since the 2.x/WebSocket migration** — verified on a live VM: with
PulseAudio completely dead, video streams fine. Anyone hitting "Waiting for
stream" and reading that comment would burn hours on PulseAudio while the real
cause was a missing `libva`. An out-of-date comment about a failure cause is
worse than no comment. After an architecture change, grep comments describing
the old behaviour.

## Also fixed

`SELKIES_MAX_RES` default raised `1920x1080` → `2560x1440`. Xvfb fixes its RANDR
`maximum` from the initial `-screen` geometry and cannot grow, so a HiDPI client
(2880x1800 panel → ~2880x1580 window) got a scaled image plus an
`RRAddOutputMode BadMatch` burst per connect, leaving orphan modes behind.
`RRCreateMode` succeeds, attaching the oversized mode does not. Cost is RAM only
(~14 MB vs ~33 MB at 4K); Selkies only scales DOWN, so a higher ceiling costs no
bitrate or CPU at smaller windows.

The earlier repo comment that Xvfb accepts `xrandr --newmode/--addmode` **up to**
the initial geometry is correct — the default was simply too low.

## Verification

```sh
/opt/selkies/venv/bin/python3 -c "import pixelflux, pcmflux, selkies"
journalctl -u selkies | grep 'pixelflux library found'          # must appear
journalctl -u selkies | grep -c 'pixelflux library unavailable' # must be 0
journalctl -u selkies | grep -ci 'PulseError'                   # must be 0
systemctl is-active xfce-session selkies x11vnc pulseaudio-system
DISPLAY=:99 xrandr | head -1                                    # maximum 2560x1440
journalctl -u selkies -f | grep 'SUCCESS: Capture started'      # the only real test
```

The last line is the only proof of a working image: until it appears, there is
no video.

## References

- `linux-debian/debian_qcow2-cloud-init-selkies.sh` — `[SELKIE]` and `[AUDIO]` blocks
- `linux-debian/selkies/start-selkies.sh.tpl`, `start-desktop.sh.tpl` — `XDG_RUNTIME_DIR`
- Migration that introduced the regression: [[1788739200-selkies-2x-websocket-migration]]
