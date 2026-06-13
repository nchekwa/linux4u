#!/usr/bin/env bash
# Selkies WebRTC stream, software x264 encoding. Attaches to the already-running
# :99 display owned by xfce-session.service.
#
# Template: ${SELKIES_USER} and ${SELKIES_PASSWORD} are filled at build time by
# the image builder (envsubst). Runtime variables (${DISPLAY}, ${HOME},
# ${XDG_RUNTIME_DIR}) are left untouched (restricted envsubst variable list).
set -euo pipefail

export DISPLAY=':99'
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# Wait until the desktop's :99 socket exists (defensive; systemd ordering also covers this)
until [ -S "/tmp/.X11-unix/X99" ]; do sleep 0.5; done

"${HOME}/selkies-gstreamer/selkies-gstreamer-run" \
  --addr=0.0.0.0 \
  --port=8080 \
  --enable_https=true \
  --https_cert=/etc/ssl/certs/ssl-cert-snakeoil.pem \
  --https_key=/etc/ssl/private/ssl-cert-snakeoil.key \
  --basic_auth_user='${SELKIES_USER}' \
  --basic_auth_password='${SELKIES_PASSWORD}' \
  --encoder=x264enc \
  --enable_resize=false
# enable_resize=false: Xvfb has a FIXED geometry (no RANDR modes to add).
