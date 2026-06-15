---
title: deskui credential menus were stale vs the selkies builder layout
date: 2026-06-15
tags: [selkies, deskui, tui, devops]
severity: medium
---

## Problem
Changing the Selkies login via `deskui` failed with
`Error: Failed to write /usr/local/bin/start-selkies.sh`. The password and VNC
password changes also "succeeded" but silently did nothing.

## Root Cause
`bin/deskui` was written for the legacy `tmp/setup-root-desktop-selkies-vnc.sh`
layout (desktop as root) and never updated when the image moved to the
`debian_qcow2-cloud-init-selkies.sh` builder layout. Four mismatches:

- Wrapper path: deskui used `/usr/local/bin/start-selkies.sh`; builder installs
  `/opt/selkies/start-selkies.sh` (`selkies.service` `ExecStart`). The missing
  file made `sed -i` exit non-zero -> the visible error.
- Login quoting: the template renders `--basic_auth_user='selkies'` (single
  quotes); deskui's `grep` captured `'selkies'` *with* quotes, so the menu/prefill
  showed quotes and `valid_token` rejected them.
- Password storage: deskui sed'd `Environment=SELKIES_PW=` in the unit, but the
  password lives in the wrapper as `--basic_auth_password='...'` (no such env in
  the unit) -> change was a no-op.
- VNC passwd path: deskui hardcoded `/root/.vnc/passwd`; builder writes
  `/home/${DESKTOP_USER}/.vnc/passwd` (x11vnc `-rfbauth`).

## Solution
Point `deskui` at the real layout: `SELKIES_WRAPPER=/opt/selkies/start-selkies.sh`,
strip quotes when reading the login (`tr -d "'"`), write login/password back
single-quoted to match the template, sed the **wrapper** (not the unit) for the
password (drop the now-needless `daemon-reload`), and discover `VNC_PASSWD` from
the x11vnc unit's `-rfbauth` (fallback `/root/.vnc/passwd` for a root-desktop
build). `deskui` is rebuilt into the image by the builder; a **running** VM keeps
the old baked copy until `/usr/local/bin/deskui` is replaced or the image is
rebuilt.

## References
- `bin/deskui`, `linux-debian/selkies/start-selkies.sh.tpl`,
  `linux-debian/selkies/x11vnc.service.tpl`,
  `linux-debian/debian_qcow2-cloud-init-selkies.sh` (install paths ~L338, L366-369)
