---
title: Selkies streaming defaults — Xvfb DOES support RANDR resize, and the default TURN server is dead
date: 2026-09-03
tags: [selkies, xvfb, randr, gstreamer, webrtc, turn, performance]
severity: high
---

## Problem

A freshly built Selkies image (Debian 13, Selkies 1.6.2, Xvfb 21.1.16, 8 vCPU) was
unusable over a real WAN link while looking fine on a LAN:

- Selkies pegged a core at **112% CPU** with an idle XFCE desktop and no user input.
- The stream was blurry on any client window that was not exactly 1920x1080.
- `journalctl -u selkies` logged `undefined symbol: g_sort_array` /
  `gst_structure_set_static_str` plugin errors on **every** service start.
- Every client connect logged `failed to set XFCE cursor size` / `failed to set XFCE DPI`.
- WebRTC connected only when direct NAT hole punching happened to succeed.

## Root Cause

Five independent defaults, each invisible on a LAN:

1. **60 fps + `ximagesrc use-damage=0`.** Selkies' `framerate` default is 60 and the
   capture element grabs a full frame every tick regardless of whether the screen
   changed, so capture, `videoconvert` (BGRx→NV12) and `x264enc` all pay the full frame
   rate on a GPU-less VM. Biggest single contributor to the idle CPU burn.
2. **`x264enc` runs `pass=cbr`.** Combined with `use-damage=0`, CBR spends the full
   target bitrate continuously — including on a completely static screen.
3. **`--enable_resize=false`, justified by a comment claiming "Xvfb has a FIXED
   geometry (no RANDR modes to add)". This is FALSE** — see below. With resize off, a
   client window larger than the framebuffer got a scaled-up (blurry) stream for no
   saving.
4. **The portable Selkies wrapper hardcodes Debian's plugin dir** into
   `GST_PLUGIN_SYSTEM_PATH`. Those `.so` files are ABI-incompatible with the bundled
   conda GStreamer, and the wrapper also `rm -rf`s `~/.cache/gstreamer-1.0` on every
   start, so the broken set is rescanned by `gst-plugin-scanner` every single time.
5. **`selkies.service` has no session D-Bus,** so `xfconf-query -c xsettings` (used by
   `resize.py` `set_dpi()` / `set_cursor_size()`) falls back to
   `dbus-launch --autolaunch`, which fails headless. DPI and cursor scaling silently
   never applied.

Plus: Selkies 1.6.2 defaults `turn_host` to `staticauth.openrelay.metered.ca` with the
public `openrelayprojectsecret`. **That host answers nothing** — UDP 443 and UDP 80 both
time out from the VM, so zero relay candidates are ever gathered
(`grep -oE "typ (host|srflx|relay)"` → `host 64`, `srflx 28`, `relay 0`). Server-side NAT
was measured as endpoint-independent and port-preserving, so the missing relay — not the
NAT — was the constraint.

## Solution

**Xvfb RANDR — verified directly, do not trust the old comment.** Running exactly the
sequence `resize.py` uses against a throwaway `Xvfb :97 -screen 0 1920x1080x24
+extension RANDR`:

```
$ xrandr --newmode 1280x800 83.50 1280 1352 1480 1680 800 803 809 831 -hsync +vsync
$ xrandr --addmode screen 1280x800
$ xrandr --output screen --mode 1280x800
Screen 0: minimum 1 x 1, current 1280 x 800, maximum 1920 x 1080   <- resized OK
```

All three succeed. The real constraint is `maximum`, fixed by the initial `-screen`
geometry: adding a mode LARGER than it fails at `--addmode` with
`X Error of failed request: BadMatch ... Major opcode 140 (RANDR)`.

**So the resolution var is a CEILING, not a working resolution** — hence the rename to
`SELKIES_MAX_RES` (with `SELKIES_RES` kept as a back-compat alias). Selkies resizes the
framebuffer down to the client's actual window, which is both sharper AND less encode
work than a permanently oversized framebuffer.

Applied fixes:

- `--framerate=30`, `--video_bitrate=8000`, `--audio_bitrate=64000` from new build vars.
- `--congestion_control=true`. **This is the important one:** it is NOT among the keys
  the runtime JSON config can override (`__main__.py` overlays only `framerate`,
  `video_bitrate`, `audio_bitrate`, `enable_resize`, `encoder` onto `args` after
  `parse_args()`), so it survives whatever the web client pushes. Keep
  `SELKIES_JSON_CONFIG` at its `/tmp/selkies_config.json` default so a bad client-side
  bitrate choice is cleared on reboot rather than made permanent.
- `--enable_resize=true`.
- GStreamer isolation via the `_1_0`-suffixed vars, which GStreamer **prefers** over the
  plain ones — so they override the vendored wrapper's own exports without patching it:
  `GST_PLUGIN_PATH_1_0=$HOME/selkies-gstreamer/lib/gstreamer-1.0`,
  `GST_PLUGIN_SYSTEM_PATH_1_0=""`,
  `GST_REGISTRY_1_0=/var/tmp/selkies-gst-registry.bin` (outside `~/.cache` so the
  wrapper's `rm -rf` cannot delete it → the scan is finally cached across restarts).
  Measured: broken plugin lines 3 → 1. The remaining one is the **bundled**
  `libgstpython` (`undefined symbol: PyUnicode_FromFormat`) inside the out-of-process
  scanner — harmless, the main process imports `gi` fine.
- Session D-Bus: `xfce-session.service` gets `RuntimeDirectory=selkies` +
  `RuntimeDirectoryPreserve=yes`; `start-desktop.sh` writes
  `/run/selkies/dbus.env`; `start-selkies.sh` sources it **after** the X-socket wait.
  Do NOT use `EnvironmentFile=` in the unit — it is read before `ExecStart`, i.e. before
  the desktop has written the file (`xfce-session.service` is `Type=simple`, so systemd
  considers it started the moment it execs). `Preserve=yes` matters because
  `RuntimeDirectory` is normally deleted when the owning unit stops, which would yank
  the file out from under a still-running `selkies.service`.
- TURN moved to build vars defaulting to EMPTY. Empty `turn_host` makes Selkies fall
  back to `DEFAULT_RTC_CONFIG` and log `missing TURN server information` — an honest
  "not configured" beats a silently dead server. **The TURN server must be reachable
  from the BROWSER, not from the VM** (Selkies serves the same `rtc_config` to the
  client, so one setting fixes both ends).

## Gotchas

- **`envsubst` runs on comments too.** Writing `${SELKIES_FRAMERATE}` inside a template
  header comment gets substituted, mangling the comment into e.g. "8000, 64000 and the".
  Spell placeholder names WITHOUT `${...}` in `.tpl` comments.
- **Every new `${...}` in a template must be added to that template's `render_tpl`
  restricted var list**, or it is left literal in the shipped image. Check with
  `grep -n '\${' /opt/selkies/start-*.sh` on the booted VM — only `${DISPLAY}`,
  `${HOME}`, `${XDG_RUNTIME_DIR}`, `${DBUS_SESSION_BUS_ADDRESS}`, `${RES}`, `${prop}`,
  `${base}` should survive.
- **`xsetroot -solid` does nothing while `xfdesktop4` is installed** — it draws over the
  root window. Use the xfconf backdrop properties instead (`image-style=0`,
  `color-style=0`), and DISCOVER the property path rather than hardcoding
  `monitorscreen`: the path embeds the RANDR output name. Enumerate via
  `xfconf-query -c xfdesktop -l | grep '/workspace0/last-image$'`.
- `start-desktop.sh` `rm -rf`s `$HOME/.config/xfce4` on EVERY start, so no XFCE setting
  can be pre-seeded at build time. Settings must be applied after the session comes up
  (background block that waits for xfconfd), or that line must go.
- Client resize triggers a short, **deliberate** reconnect (the server sends the new
  resolution and the client reloads the stream after ~700 ms). Do not mistake it for a
  failure loop.
- `resize.py` shells out to `cvt` (from `xserver-xorg-core`) and `xrandr` (from
  `x11-xserver-utils`) — both already in the image's package list.

## Known remaining issue (out of scope)

The **audio PeerConnection never gathers a server-reflexive candidate** (6 of 6 observed
sessions: only the private address and a link-local `fe80::`), while the video one gets
`srflx` every time — despite both `webrtcbin` instances demonstrably receiving the same
STUN/TURN config, and STUN itself answering 4/4 concurrent binding requests. Looks like a
`webrtcbin`/libnice gathering bug in the second agent; **root cause unexplained at the
library level.** The consequence is client-side: `app.js` gates the whole UI on BOTH
connections, and the audio disconnect handler tears down a perfectly healthy video
connection. A working TURN server masks this by giving audio a relay candidate. A direct
fix would mean patching `share/selkies-web/app.js` at build time, which would need
re-basing on every Selkies bump — not done.

## References

- CR SELKIES-PERF-001 (CR-1..CR-8)
- `linux-debian/selkies/start-selkies.sh.tpl`, `start-desktop.sh.tpl`,
  `xfce-session.service.tpl`, `selkies.service.tpl`
- `linux-debian/debian_qcow2-cloud-init-selkies.sh`
