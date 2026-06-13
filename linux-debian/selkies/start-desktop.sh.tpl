#!/usr/bin/env bash
# Foundation: a headless virtual X11 display (:99) running an XFCE session.
# Independent of any remote-access client (Selkies / VNC attach to it later).
#
# Template: ${SELKIES_RES} is filled at build time by the image builder
# (envsubst). Runtime variables (${DISPLAY}, ${HOME}, ${XDG_RUNTIME_DIR}) are
# left untouched because envsubst is called with a restricted variable list.
set -euo pipefail

export DISPLAY=':99'
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
RES='${SELKIES_RES}'

# Virtual X11 framebuffer (no physical monitor / no GPU)
exec_xvfb() {
  Xvfb "${DISPLAY}" -screen 0 "${RES}x24" \
    +extension COMPOSITE +extension DAMAGE +extension GLX +extension RANDR \
    +extension RENDER +extension MIT-SHM +extension XFIXES +extension XTEST \
    -nolisten tcp -ac -noreset >/tmp/Xvfb.log 2>&1 &
}
exec_xvfb

echo 'Waiting for X socket'
until [ -S "/tmp/.X11-unix/X${DISPLAY#*:}" ]; do sleep 0.5; done
echo 'X server ready'

# Run the XFCE session in the FOREGROUND so systemd tracks this unit's liveness
# by the desktop session itself (Type=simple stays active while XFCE runs).
rm -rf "${HOME}/.config/xfce4"
exec startxfce4
