#!/usr/bin/env bash
# Selkies WebRTC stream, software x264 encoding. Attaches to the already-running
# :99 display owned by xfce-session.service.
#
# Template: the SELKIES_USER / SELKIES_PASSWORD / SELKIES_FRAMERATE /
# SELKIES_VIDEO_BITRATE / SELKIES_AUDIO_BITRATE / SELKIES_TURN_* placeholders
# below are filled at build time by the image builder (envsubst). Runtime
# variables (${DISPLAY}, ${HOME}, ${XDG_RUNTIME_DIR}) are left untouched
# (restricted envsubst variable list). Names are spelled without ${...} here on
# purpose so envsubst does not rewrite this comment.
set -euo pipefail

export DISPLAY=':99'
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# Wait until the desktop's :99 socket exists (defensive; systemd ordering also covers this)
until [ -S "/tmp/.X11-unix/X99" ]; do sleep 0.5; done

# Session D-Bus published by start-desktop.sh. Without it xfconf-query fails and
# DPI / cursor scaling silently never applies. Read AFTER the X wait:
# xfce-session.service is Type=simple, so an EnvironmentFile= in the unit would
# be read before the desktop has written this.
if [ -f /run/selkies/dbus.env ]; then
  export "$(cat /run/selkies/dbus.env)"
fi

# The portable build's wrapper hardcodes Debian's /usr/lib/.../gstreamer-1.0 into
# GST_PLUGIN_SYSTEM_PATH. Those plugins are ABI-incompatible with the bundled conda
# GStreamer (undefined symbol: g_sort_array / gst_structure_set_static_str), and the
# wrapper also rm -rf's ~/.cache/gstreamer-1.0 every start, so they get rescanned
# every time. GStreamer prefers the _1_0 variants, so these override the wrapper.
export GST_PLUGIN_PATH_1_0="${HOME}/selkies-gstreamer/lib/gstreamer-1.0"
export GST_PLUGIN_SYSTEM_PATH_1_0=""
# Registry outside ~/.cache survives the wrapper's rm -rf -> scan is cached.
export GST_REGISTRY_1_0="/var/tmp/selkies-gst-registry.bin"

"${HOME}/selkies-gstreamer/selkies-gstreamer-run" \
  --addr=0.0.0.0 \
  --port=8080 \
  --enable_https=true \
  --https_cert=/etc/ssl/certs/ssl-cert-snakeoil.pem \
  --https_key=/etc/ssl/private/ssl-cert-snakeoil.key \
  --basic_auth_user='${SELKIES_USER}' \
  --basic_auth_password='${SELKIES_PASSWORD}' \
  --encoder=x264enc \
  --framerate='${SELKIES_FRAMERATE}' \
  --video_bitrate='${SELKIES_VIDEO_BITRATE}' \
  --audio_bitrate='${SELKIES_AUDIO_BITRATE}' \
  --congestion_control=true \
  --enable_resize=true \
  --turn_host='${SELKIES_TURN_HOST}' \
  --turn_port='${SELKIES_TURN_PORT}' \
  --turn_protocol='${SELKIES_TURN_PROTOCOL}' \
  --turn_username='${SELKIES_TURN_USERNAME}' \
  --turn_password='${SELKIES_TURN_PASSWORD}'
#
# enable_resize=true: Xvfb DOES accept xrandr --newmode/--addmode/--output --mode,
# up to the initial -screen geometry which start-desktop.sh sets to SELKIES_MAX_RES.
# (An earlier comment here claimed otherwise; verified false on Xvfb 21.1.16.)
#
# congestion_control=true is the one encoder setting the client cannot override:
# the runtime JSON config only overlays framerate/video_bitrate/audio_bitrate/
# enable_resize/encoder onto args. x264enc runs pass=cbr, so without GCC it
# spends the full target bitrate even on a completely static screen.
#
# Empty turn_host makes Selkies fall back to its DEFAULT_RTC_CONFIG and log
# "missing TURN server information" -- an honest "not configured" beats the
# upstream default (staticauth.openrelay.metered.ca), which answers nothing.
