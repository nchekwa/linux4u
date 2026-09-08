#!/usr/bin/env bash
# Selkies WebSocket stream, software H.264 encoding. Attaches to the
# already-running :99 display owned by xfce-session.service.
#
# Template: the SELKIES_USER / SELKIES_PASSWORD / SELKIES_FRAMERATE /
# SELKIES_VIDEO_BITRATE / SELKIES_AUDIO_BITRATE placeholders below are filled at
# build time by the image builder (envsubst). Runtime variables (${DISPLAY},
# ${HOME}, ${XDG_RUNTIME_DIR}) are left untouched (restricted envsubst variable
# list). Names are spelled without ${...} here on purpose so envsubst does not
# rewrite this comment.
set -euo pipefail

export DISPLAY=':99'
# NOT /tmp: it is root-owned 1777, and PulseAudio correctly refuses a runtime dir
# it does not own ("XDG_RUNTIME_DIR (/tmp) is not owned by us, but by uid 0"),
# turning a clear "no runtime dir" condition into a misleading "connection
# refused". This service has no PAMName=login, so logind never creates
# /run/user/<uid>; /run/selkies is owned by the desktop user and comes from
# RuntimeDirectory=selkies in xfce-session.service (Preserve=yes keeps it alive).
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/selkies}"

# Wait until the desktop's :99 socket exists (defensive; systemd ordering also covers this)
until [ -S "/tmp/.X11-unix/X99" ]; do sleep 0.5; done

# Session D-Bus published by start-desktop.sh. Without it xfconf-query fails and
# DPI / cursor scaling silently never applies. Read AFTER the X wait:
# xfce-session.service is Type=simple, so an EnvironmentFile= in the unit would
# be read before the desktop has written this.
if [ -f /run/selkies/dbus.env ]; then
  export "$(cat /run/selkies/dbus.env)"
fi

/opt/selkies/venv/bin/selkies \
  --mode=websockets \
  --enable_dual_mode=false \
  --web_root=/opt/selkies/web \
  --addr=0.0.0.0 \
  --port=8080 \
  --enable_https=true \
  --https_cert=/etc/ssl/certs/ssl-cert-snakeoil.pem \
  --https_key=/etc/ssl/private/ssl-cert-snakeoil.key \
  --basic_auth_user='${SELKIES_USER}' \
  --basic_auth_password='${SELKIES_PASSWORD}' \
  --encoder=h264enc \
  --framerate='${SELKIES_FRAMERATE}' \
  --video_bitrate='${SELKIES_VIDEO_BITRATE}' \
  --audio_bitrate='${SELKIES_AUDIO_BITRATE}' \
  --congestion_control=true \
  --enable_resize=true
#
# mode=websockets is the whole point of this image: frames go over ONE outbound
# TCP connection on :8080, so an ordinary reverse proxy (or Cloudflare's
# orange-cloud, which carries no UDP) can carry it. WebRTC cannot.
#
# enable_dual_mode=false is NOT redundant: it defaults to TRUE upstream, and
# leaving it on lets the web client switch itself back to WebRTC at runtime,
# reintroducing exactly the failure this image exists to avoid.
#
# web_root: the web client is NOT packaged in a source install (upstream only
# bundles it into released wheels), so the builder compiles it with vite and
# copies it here. Without this Selkies dies on "No module named
# 'selkies.selkies_web'".
#
# encoder=h264enc is the 2.x name (allowed: h264enc, openh264enc,
# h264enc-striped, jpeg). The old x264enc is silently aliased to it, but the
# alias is undocumented -- spell the real name.
#
# enable_resize=true: Xvfb DOES accept xrandr --newmode/--addmode/--output --mode,
# up to the initial -screen geometry which start-desktop.sh sets from
# SELKIES_MAX_RES (the ceiling, default 3840x2160). The desktop BOOTS at
# SELKIES_RES (default 1920x1080) instead, which start-desktop.sh applies under
# that ceiling; the resize below then follows the client window. A client asking
# for MORE than the ceiling is the one case that silently fails: the mode is
# created but never attached, so the desktop stays smaller than the browser
# viewport and its right/bottom edges (window buttons) fall outside it.
#
# congestion_control=true is the one encoder setting the client cannot override:
# the runtime JSON config only overlays framerate/video_bitrate/audio_bitrate/
# enable_resize/encoder onto args.
#
# No turn_*/stun_* flags: NAT traversal is meaningless for a single outbound TCP
# connection, and those options are never read in websockets mode.
