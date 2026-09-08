#!/usr/bin/env bash
# Foundation: a headless virtual X11 display (:99) running an XFCE session.
# Independent of any remote-access client (Selkies / VNC attach to it later).
#
# Template: the SELKIES_MAX_RES / SELKIES_RES placeholders are filled at build
# time by the builder (envsubst). Runtime variables (${DISPLAY}, ${HOME},
# ${XDG_RUNTIME_DIR}) are left untouched because envsubst is called with a
# restricted variable list.
set -euo pipefail

export DISPLAY=':99'
# NOT /tmp: root-owned 1777, which PulseAudio refuses as a runtime dir (see
# start-selkies.sh). /run/selkies is this unit's own RuntimeDirectory=selkies,
# owned by the desktop user.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/selkies}"

# CEILING for the framebuffer, not the working resolution. Selkies resizes DOWN
# to the client's window size on connect (enable_resize=true); this only caps how
# large it may get. Xvfb's RANDR 'maximum' is fixed by this initial -screen geometry.
MAX_RES='${SELKIES_MAX_RES}'
# STARTING mode, applied under that ceiling once X is up (see below). Xvfb boots
# the screen AT the ceiling, so without this the desktop would come up at 4K.
START_RES='${SELKIES_RES}'

# Virtual X11 framebuffer (no physical monitor / no GPU)
exec_xvfb() {
  Xvfb "${DISPLAY}" -screen 0 "${MAX_RES}x24" \
    +extension COMPOSITE +extension DAMAGE +extension GLX +extension RANDR \
    +extension RENDER +extension MIT-SHM +extension XFIXES +extension XTEST \
    -nolisten tcp -ac -noreset >/tmp/Xvfb.log 2>&1 &
}
exec_xvfb

echo 'Waiting for X socket'
until [ -S "/tmp/.X11-unix/X${DISPLAY#*:}" ]; do sleep 0.5; done
echo 'X server ready'

# Drop from the ceiling to the starting mode BEFORE XFCE starts, so the session
# lays its panels out for START_RES instead of the full framebuffer. Xvfb already
# advertises common modes below 'maximum', but the exact geometry is not
# guaranteed to be among them -- create it if missing. Non-fatal throughout: a
# desktop at the ceiling still works, and Selkies resizes on connect anyway.
set_start_mode() {
  local out mode
  out="$(xrandr --query | awk '/ connected/{print $1; exit}')" || return 0
  [ -n "${out}" ] || return 0
  mode="${START_RES}"

  # Xvfb boots with ONLY the ceiling mode advertised, so the starting mode almost
  # always has to be created first.
  if ! xrandr --query | grep -qE "^[[:space:]]+${mode}[[:space:]]"; then
    local w h
    w="${mode%x*}"; h="${mode#*x}"
    # Timings are deliberately fake: there is no monitor and no pixel clock to
    # respect, so a dummy modeline is enough for RANDR to accept the geometry.
    # Computed inline rather than via cvt(1) to avoid depending on it.
    # shellcheck disable=SC2086  # deliberate word splitting: xrandr wants 12 args
    xrandr --newmode "${mode}" 60.00 \
      "${w}" "${w}" "${w}" "${w}" \
      "${h}" "${h}" "${h}" "${h}" \
      -hsync +vsync 2>/dev/null || true
    xrandr --addmode "${out}" "${mode}" 2>/dev/null || true
  fi

  xrandr --output "${out}" --mode "${mode}" 2>/dev/null \
    || echo "WARN: could not set ${mode} on ${out}, staying at ${MAX_RES}" >&2
}
[ "${START_RES}" = "${MAX_RES}" ] || set_start_mode

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
