#!/usr/bin/env bash
#
# setup-root-desktop-selkies-vnc.sh
#
# Stand up a headless XFCE4 desktop on Xvfb :99, streamed by selkies-gstreamer
# (WebRTC HTML5) and mirrored by x11vnc -- ALL running as the root user --
# on an already-running Debian 12 (bookworm) / 13 (trixie) server.
#
# Target: a disposable / lab VM. Security trade-offs (Chromium --no-sandbox,
# Xvfb -ac, basic-auth over HTTP) are accepted deliberately. Do NOT use on a
# shared or internet-exposed host.
#
# NOTE ON GSTREAMER: we deliberately use Debian's NATIVE GStreamer stack
# (python3-gst-1.0 + plugins) instead of selkies' prebuilt /opt bundle. The
# prebuilt bundle ships Python bindings compiled for the *Ubuntu* build's Python
# minor version (e.g. ubuntu24.04 -> Python 3.12) and refuses to load on Debian's
# Python (bookworm 3.11 / trixie 3.13) -- ABI mismatch. The native stack matches
# the system Python and is the robust path. Only the static web bundle and the
# pure-python wheel are taken from the selkies release.
#
# Idempotent: safe to re-run. scp to the server and run as root.
#
set -euo pipefail

# ==========================================================================
# Configuration -- edit these before running
# ==========================================================================
SELKIES_PW="${SELKIES_PW:-changeme}"          # selkies web UI password (user: root)
VNC_PW="${VNC_PW:-changeme}"                   # x11vnc password
SCREEN="${SCREEN:-1920x1080x24}"               # Xvfb screen geometry
ENCODER="${ENCODER:-x264enc}"                  # x264enc (CPU) | nvh264enc | vah264enc | vp8enc | vp9enc
REMOVE_USER="${REMOVE_USER:-false}"            # true => DESTRUCTIVE: deluser --remove-home $USER_TO_REMOVE
USER_TO_REMOVE="${USER_TO_REMOVE:-user}"       # the non-root account to retire when REMOVE_USER=true
SELKIES_VERSION="${SELKIES_VERSION:-}"         # blank => auto-detect latest release
FORCE_SELKIES="${FORCE_SELKIES:-false}"        # true => re-download/reinstall selkies even if present

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

# ==========================================================================
# Step 0 -- Prereqs & version detection
# ==========================================================================
[ "$(id -u)" -eq 0 ] || die "run as root"

detect_versions() {
  if [ -z "$SELKIES_VERSION" ]; then
    SELKIES_VERSION="$(curl -fsSL https://api.github.com/repos/selkies-project/selkies/releases/latest \
      | jq -r .tag_name | sed 's/^v//')"
    [ -n "$SELKIES_VERSION" ] && [ "$SELKIES_VERSION" != "null" ] || die "could not auto-detect SELKIES_VERSION"
  fi
  log "selkies v${SELKIES_VERSION} | native Debian GStreamer | encoder ${ENCODER}"
}

# ==========================================================================
# Step 1 -- Packages: X11 + XFCE4 + x11vnc + chromium + native GStreamer stack
# ==========================================================================
install_packages() {
  log "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    xserver-xorg-core xinit xvfb dbus-x11 x11-utils x11-xkb-utils x11-xserver-utils x11-apps x11vnc \
    xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings xfce4-terminal thunar mousepad \
    chromium ssl-cert python3 python3-pip curl jq ca-certificates xdotool xsel xclip \
    python3-gi python3-gst-1.0 \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav gstreamer1.0-tools gstreamer1.0-nice gstreamer1.0-pulseaudio \
    gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 gir1.2-gst-plugins-bad-1.0
}

# ==========================================================================
# Step 2 -- selkies: web bundle (static) + python wheel under SYSTEM python3
# ==========================================================================
install_selkies() {
  if [ "$FORCE_SELKIES" != "true" ] && /usr/bin/python3 -c "import selkies_gstreamer" 2>/dev/null && [ -d /opt/gst-web ]; then
    log "selkies already installed for system python3 (FORCE_SELKIES=true to reinstall) -- skipping"
    return 0
  fi
  log "Installing selkies web bundle + python wheel (system python3)"
  local base="https://github.com/selkies-project/selkies/releases/download/v${SELKIES_VERSION}"
  ( cd /opt && curl -fsSL "${base}/selkies-gstreamer-web_v${SELKIES_VERSION}.tar.gz" | tar -xzf - )
  ( cd /tmp && curl -O -fsSL "${base}/selkies_gstreamer-${SELKIES_VERSION}-py3-none-any.whl" )
  # No --force-reinstall: it would try to remove apt-managed deps (e.g. python3-psutil)
  # that pip cannot uninstall (no RECORD file). Plain install keeps distro packages intact.
  /usr/bin/python3 -m pip install --break-system-packages --no-cache-dir \
    "/tmp/selkies_gstreamer-${SELKIES_VERSION}-py3-none-any.whl"
  [ -d /opt/gst-web ] || die "selkies web bundle missing /opt/gst-web"
  /usr/bin/python3 -c "import selkies_gstreamer" || die "selkies_gstreamer not importable under system python3"
  # Sanity: the GStreamer Python stack must load under the system Python.
  /usr/bin/python3 -c "import gi; gi.require_version('Gst','1.0'); gi.require_version('GstWebRTC','1.0'); from gi.repository import Gst, GstWebRTC" \
    || die "GStreamer/GstWebRTC bindings not available -- check gstreamer1.0-* and gir1.2-gst-* packages"
}

# ==========================================================================
# Step 3 -- Chromium --no-sandbox (unavoidable root fix)
# ==========================================================================
configure_chromium() {
  log "Configuring Chromium for root (--no-sandbox)"
  mkdir -p /etc/chromium.d
  printf 'export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox --test-type"\n' > /etc/chromium.d/00-no-sandbox
}

# ==========================================================================
# Step 4 -- PulseAudio system mode + virtual sink (REQUIRED by selkies)
# ==========================================================================
# selkies 1.6.2 has no flag to disable audio: on every client connect it opens an
# audio pipeline via pulsesrc. With no PulseAudio that pipeline fails with
# GST_STATE_CHANGE_FAILURE, which aborts the session handler BEFORE the video
# pipeline starts -- the browser then sits forever on "Waiting for stream".
# A dummy null sink (no real hardware) is enough to satisfy it.
configure_audio() {
  log "Configuring PulseAudio system mode + virtual sink (required by selkies)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends pulseaudio pulseaudio-utils
  usermod -aG audio pulse 2>/dev/null || true
  usermod -aG pulse-access root
  if ! grep -q virtual-speaker /etc/pulse/system.pa 2>/dev/null; then
    cat >> /etc/pulse/system.pa <<'EOF'

# --- added by setup-root-desktop-selkies-vnc.sh ---
load-module module-null-sink sink_name=virtual-speaker sink_properties=device.description=virtual-speaker
set-default-sink virtual-speaker
set-default-source virtual-speaker.monitor
EOF
  fi
  cat > /etc/systemd/system/pulseaudio-system.service <<'EOF'
[Unit]
Description=PulseAudio system daemon (root/lab)
After=network.target

[Service]
ExecStart=/usr/bin/pulseaudio --system --disallow-exit --log-target=journal
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

# ==========================================================================
# Step 5 -- Xvfb + XFCE units (root)
# ==========================================================================
write_display_units() {
  log "Writing xvfb + xfce-session units"
  cat > /etc/systemd/system/xvfb.service <<EOF
[Unit]
Description=Xvfb virtual display :99
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 ${SCREEN} +extension COMPOSITE +extension RANDR +extension RENDER +extension GLX -nolisten tcp -ac -noreset
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/xfce-session.service <<'EOF'
[Unit]
Description=XFCE session on :99 (root)
After=xvfb.service
Requires=xvfb.service

[Service]
User=root
Environment=DISPLAY=:99
Environment=HOME=/root
Environment=XDG_RUNTIME_DIR=/run/user/0
ExecStartPre=/bin/mkdir -p -m 700 /run/user/0
ExecStart=/usr/bin/dbus-launch --exit-with-session /usr/bin/startxfce4
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

# ==========================================================================
# Step 6 -- selkies wrapper + service (root, system GStreamer)
# ==========================================================================
write_selkies_service() {
  log "Writing selkies wrapper + service"
  cat > /usr/local/bin/start-selkies.sh <<EOF
#!/usr/bin/env bash
set -e
# Debian: use the distro GStreamer stack (python3-gst-1.0), NOT the version-locked
# /opt selkies bundle (bindings compiled for the Ubuntu build's Python minor version).
exec /usr/bin/python3 -m selkies_gstreamer \\
  --addr=0.0.0.0 --port=8080 --enable_https=false \\
  --basic_auth_user=root --basic_auth_password="\${SELKIES_PW:-changeme}" \\
  --encoder=${ENCODER} --enable_resize=false --web_root=/opt/gst-web
EOF
  chmod +x /usr/local/bin/start-selkies.sh

  local pulse_env="Environment=PULSE_SERVER=unix:/run/pulse/native"

  cat > /etc/systemd/system/selkies.service <<EOF
[Unit]
Description=Selkies WebRTC stream of :99 (root)
After=xfce-session.service
Requires=xfce-session.service

[Service]
User=root
Environment=DISPLAY=:99
Environment=HOME=/root
Environment=XDG_RUNTIME_DIR=/run/user/0
${pulse_env}
Environment=SELKIES_PW=${SELKIES_PW}
ExecStartPre=/bin/mkdir -p -m 700 /run/user/0
ExecStart=/usr/local/bin/start-selkies.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

# ==========================================================================
# Step 7 -- x11vnc service (root, localhost only)
# ==========================================================================
write_vnc_service() {
  log "Writing x11vnc service + password"
  mkdir -p /root/.vnc
  x11vnc -storepasswd "$VNC_PW" /root/.vnc/passwd >/dev/null
  cat > /etc/systemd/system/x11vnc.service <<'EOF'
[Unit]
Description=x11vnc sharing :99 (root)
After=xfce-session.service
Requires=xvfb.service

[Service]
User=root
Environment=DISPLAY=:99
ExecStart=/usr/bin/x11vnc -display :99 -rfbauth /root/.vnc/passwd -localhost -forever -shared -rfbport 5900
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

# ==========================================================================
# Step 8 -- Enable & start everything
# ==========================================================================
enable_services() {
  log "Enabling & starting services"
  systemctl daemon-reload
  local units="pulseaudio-system.service xvfb.service xfce-session.service selkies.service x11vnc.service"
  systemctl reset-failed $units 2>/dev/null || true
  systemctl enable --now $units
}

# ==========================================================================
# Step 9 -- Retire the non-root account (DESTRUCTIVE, opt-in)
# ==========================================================================
maybe_remove_user() {
  if [ "$REMOVE_USER" != "true" ]; then
    log "Keeping '$USER_TO_REMOVE' account (set REMOVE_USER=true to delete it) -- skipping"
    return 0
  fi
  if id "$USER_TO_REMOVE" >/dev/null 2>&1; then
    warn "DESTRUCTIVE: removing account '$USER_TO_REMOVE' and its home"
    pkill -KILL -u "$USER_TO_REMOVE" 2>/dev/null || true
    deluser --remove-home "$USER_TO_REMOVE" || warn "deluser failed (account may be in use)"
  else
    log "Account '$USER_TO_REMOVE' does not exist -- nothing to remove"
  fi
}

# ==========================================================================
# Run
# ==========================================================================
main() {
  detect_versions
  install_packages
  install_selkies
  configure_chromium
  configure_audio
  write_display_units
  write_selkies_service
  write_vnc_service
  enable_services
  maybe_remove_user

  log "Done. Verify with:"
  cat <<EOF
  systemctl is-active xvfb xfce-session selkies x11vnc
  curl -u root:${SELKIES_PW} http://127.0.0.1:8080/        # selkies web UI (expect HTTP 200)
  ss -ltnp | grep 5900                                     # x11vnc on 127.0.0.1
  # Browser: http://<server-ip>:8080  (root / ${SELKIES_PW})
  # VNC:     ssh -L 5900:localhost:5900 root@<server-ip>  then connect localhost:5900
EOF
}

main "$@"
