#!/usr/bin/env bash
# Foundation: a headless virtual X11 display (:99) running an XFCE session.
# Independent of any remote-access client (Selkies / VNC attach to it later).
#
# Template: the SELKIES_MAX_RES placeholder is filled at build time by the builder
# (envsubst). Runtime variables (${DISPLAY}, ${HOME}, ${XDG_RUNTIME_DIR}) are
# left untouched because envsubst is called with a restricted variable list.
set -euo pipefail

export DISPLAY=':99'
# NOT /tmp: root-owned 1777, which PulseAudio refuses as a runtime dir (see
# start-selkies.sh). /run/selkies is this unit's own RuntimeDirectory=selkies,
# owned by the desktop user.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/selkies}"

# CEILING for the framebuffer, not the working resolution. Selkies resizes DOWN
# to the client's window size on connect (enable_resize=true); this only caps how
# large it may get. Xvfb's RANDR 'maximum' is fixed by this initial -screen geometry.
RES='${SELKIES_MAX_RES}'

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

# NOTE: this wipes the user's XFCE config on EVERY start, which is why the
# settings block below cannot simply be baked into the image. Keep it if you want
# a guaranteed clean session per boot; drop it if users should keep their settings.
rm -rf "${HOME}/.config/xfce4"

# Streaming-friendly XFCE settings. Applied in the BACKGROUND because they need
# xfconfd, which only comes up with the session (started by the exec below); the
# loop waits for it. Runs after the wipe above, so the settings survive.
(
  for _ in $(seq 1 60); do
    xfconf-query -c xfwm4 -l >/dev/null 2>&1 && break
    sleep 0.5
  done
  # Compositing costs redraws and damage events for no benefit on a stream
  xfconf-query -c xfwm4 -p /general/use_compositing -s false --create -t bool || true
  # Flat backdrop: a photographic wallpaper is the worst case for a CBR H.264
  # stream - constant residual noise burns bitrate on pixels nobody looks at.
  # image-style=0 (none) + color-style=0 (solid).
  # The backdrop property path embeds the RANDR output name, so discover it
  # instead of hardcoding it.
  xfconf-query -c xfdesktop -l 2>/dev/null | grep '/workspace0/last-image$' | while read -r prop; do
    base="${prop%/last-image}"
    xfconf-query -c xfdesktop -p "${base}/image-style" -s 0 --create -t int || true
    xfconf-query -c xfdesktop -p "${base}/color-style" -s 0 --create -t int || true
  done
) &

# Session D-Bus, shared with selkies.service so xfconf-query works there too
# (DPI + cursor scaling on client resize). /run/selkies comes from
# RuntimeDirectory= in xfce-session.service.
eval "$(dbus-launch --sh-syntax)"
printf 'DBUS_SESSION_BUS_ADDRESS=%s\n' "${DBUS_SESSION_BUS_ADDRESS}" > /run/selkies/dbus.env

# Run the XFCE session in the FOREGROUND so systemd tracks this unit's liveness
# by the desktop session itself (Type=simple stays active while XFCE runs).
exec startxfce4
