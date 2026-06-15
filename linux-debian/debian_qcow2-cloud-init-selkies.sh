#!/bin/sh
# debian_qcow2-selkies.sh
# -----------------------------------------------------------------------------
# Builds a Debian cloud qcow2 image preloaded with:
#   - Selkies (X11) WebRTC HTML5 remote desktop, software x264 encoding
#   - XFCE4 lightweight desktop (no goodies, no games, no bloat)
#   - Chromium browser + a minimal set of basic apps + terminal
#   - Xvfb virtual X11 display (no hardware video encoder available)
#
# Based on nchekwa/linux4u debian_qcow2.sh (same conventions: virt-customize
# blocks, cloud-init eni renderer, netui, DNS via resolvconf, guest agents).
# -----------------------------------------------------------------------------

ROOT_PASSWORD="root"
TIMEZONE="UTC"
DEBUG="${DEBUG:-false}"
FINAL_NAME="${FINAL_NAME:-$FILE_PATH}"

# Desktop user. Default is a normal user (recommended). LAB CORNER CASE: set
# DESKTOP_USER=root to build a root desktop image -- the whole stack then runs as
# root and the root-only fixes kick in (HOME=/root, system PulseAudio, chromium
# --no-sandbox). Do NOT use a root image for anything exposed; see [ROOT] below.
DESKTOP_USER="${DESKTOP_USER:-user}"
DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-user}"

# Home the desktop session uses. root's real home is /root; a normal user's is
# /home/<user>. Everything (baked Selkies, VNC passwd, service paths) keys off
# this so the same templates work for both.
if [ "$DESKTOP_USER" = "root" ]; then
  DESKTOP_HOME="/root"
else
  DESKTOP_HOME="/home/${DESKTOP_USER}"
fi

# Selkies HTTP basic-auth credentials (web UI login)
SELKIES_USER="${SELKIES_USER:-selkies}"
SELKIES_PASSWORD="${SELKIES_PASSWORD:-321selkies}"
# Streamed virtual display geometry
SELKIES_RES="${SELKIES_RES:-1920x1080}"

# VNC password (separate from the Linux user password; VNC uses its own scheme).
# x11vnc shares the SAME :99 display as Selkies, bound to localhost only.
# Reach it via SSH tunnel:  ssh -L 5900:127.0.0.1:5900 user@VM  then connect a
# VNC viewer to 127.0.0.1:5900.
VNC_PASSWORD="${VNC_PASSWORD:-321vnc}"

# Payload source: the service files and start scripts live in the repo under
# linux-debian/selkies/ and are pulled at build time, so this builder stays a
# single downloadable file. Pin to a tag/SHA for reproducible builds.
LINUX4U_REF="${LINUX4U_REF:-main}"
LINUX4U_REPO="https://raw.githubusercontent.com/nchekwa/linux4u/${LINUX4U_REF}"

# Exported for envsubst when rendering the .tpl payloads on the host.
export DESKTOP_USER DESKTOP_HOME SELKIES_USER SELKIES_PASSWORD SELKIES_RES

# Check if version argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <version:12|13>"
    exit 1
fi

VERSION="$1"

case "$VERSION" in
    "12")
        FILE_PATH="debian-12-genericcloud-amd64.qcow2"
        URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
        ;;
    "13")
        FILE_PATH="debian-13-genericcloud-amd64.qcow2"
        URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
        ;;
    *)
        echo "Invalid version. Supported versions are 12 and 13."
        exit 1
        ;;
esac

echo "Selected version: $VERSION"
echo "URL: $URL"
if [ -z "$FINAL_NAME" ]; then
    FINAL_NAME="debian-${VERSION}-amd64-cloud-init-selkies.qcow2"
    echo "Final name: $FINAL_NAME"
else
    FINAL_NAME="$FILE_PATH"
    echo "Final name: $FINAL_NAME"
fi


# ### Set Debug in case of troubleshooting
if [ "$DEBUG" = "true" ]; then
    export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
fi


echo "[    ..] Install local tools necessary to run virt..."
sudo apt update -y && sudo apt install nano wget curl libguestfs-tools libvirt-login-shell 7zip gettext-base -y


# -----------------------------------------------------------------------------
# Payload fetch helpers. curl runs on the HOST (not inside the libguestfs
# appliance) so it is unaffected by the build-time DNS swap done by the [DNS]
# block; rendered files are injected with virt-customize --copy-in. Templated
# payloads (.tpl) are filled with envsubst using a RESTRICTED variable list, so
# only the named build-time vars are substituted and runtime ${HOME}/${DISPLAY}
# are left literal.
# -----------------------------------------------------------------------------
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT

fetch_payload() {
  # $1 = filename in linux-debian/selkies/, $2 = output name in BUILD_TMP
  curl -fsSL "${LINUX4U_REPO}/linux-debian/selkies/$1" -o "${BUILD_TMP}/$2" \
    || { echo "[  FAIL] fetch payload $1"; exit 1; }
}

fetch_base() {
  # $1 = filename in linux-debian/base/ (shared payloads), $2 = output name in BUILD_TMP
  curl -fsSL "${LINUX4U_REPO}/linux-debian/base/$1" -o "${BUILD_TMP}/$2" \
    || { echo "[  FAIL] fetch base $1"; exit 1; }
}

render_tpl() {
  # $1 = .tpl name in linux-debian/selkies/, $2 = output in BUILD_TMP, $3 = envsubst var list
  curl -fsSL "${LINUX4U_REPO}/linux-debian/selkies/$1" -o "${BUILD_TMP}/$1" \
    || { echo "[  FAIL] fetch template $1"; exit 1; }
  envsubst "$3" < "${BUILD_TMP}/$1" > "${BUILD_TMP}/$2"
}


echo "[   ISO] Download Debian img if not exist"
if [ ! -e "$FILE_PATH" ]; then
    echo "[    ..] File does not exist. Downloading..."
    wget "$URL"
else
    echo "[    OK] File already exists."
fi


echo "[    TZ] set timezone UTC"
virt-customize -a $FILE_PATH --timezone $TIMEZONE

echo "[  ROOT] set root password"
virt-customize -a $FILE_PATH --root-password password:$ROOT_PASSWORD

echo "[   SSH] enable password auth to yes"
virt-customize -a $FILE_PATH --run-command 'sed -i s/^PasswordAuthentication.*/PasswordAuthentication\ yes/ /etc/ssh/sshd_config'
echo "[   SSH] allow root login with ssh-key only"
virt-customize -a $FILE_PATH --run-command 'sed -i s/^#PermitRootLogin.*/PermitRootLogin\ yes/ /etc/ssh/sshd_config'


# Desktop + Chromium + Selkies need more room than the headless ~2.2GB base.
echo "[  DISK] - increase sda disk to 12G (original is ~2.2GB)"
qemu-img resize $FILE_PATH 12G
echo "[  DISK] - change sda1 partition size"
virt-customize -a $FILE_PATH --run-command "growpart /dev/sda 1 &&  resize2fs /dev/sda1"


echo "[   NET] - set net.ifnames=0 biosdevname=0"
virt-customize -a $FILE_PATH \
  --edit '/etc/default/grub:s/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 /' \
  --run-command 'update-grub'

echo "[   NET] - make cloud-init render network via ifupdown (eni renderer)"
fetch_base 99-eni.cfg 99-eni.cfg
virt-customize -a $FILE_PATH \
  --run-command 'mkdir -p /etc/cloud/cloud.cfg.d' \
  --copy-in "${BUILD_TMP}/99-eni.cfg:/etc/cloud/cloud.cfg.d"
# Unify on ifupdown: force cloud-init to render to /etc/network/interfaces(.d) via the eni renderer
# instead of netplan/network-manager. DNS handled by resolvconf (see the [DNS] block).

echo "[   NET] - pre-seed eth0 DHCP default for boots with no cloud-init datasource"
fetch_base 50-cloud-init 50-cloud-init
virt-customize -a $FILE_PATH \
  --run-command 'mkdir -p /etc/network/interfaces.d' \
  --copy-in "${BUILD_TMP}/50-cloud-init:/etc/network/interfaces.d"
# Debian ds-identify DISABLES cloud-init when no datasource is found, and genericcloud ships no
# static eth0 - so a VM booted WITHOUT a cloud-init drive would render nothing and eth0 would stay
# "qdisc noop state DOWN". Pre-seeding cloud-init's own eni render path with a DHCP stanza fixes
# this with a SINGLE file: cloud-init OVERWRITES it when a datasource is present, and leaves it
# untouched when disabled (eth0 comes up on DHCP; dhcpcd handles IPv6 via RA). Verified on live
# qemu/KVM VMs both WITH and WITHOUT a datasource. See docs/notes/learnings.


echo "[   APT] Update + upgrade base image"
virt-customize -a $FILE_PATH --run-command 'apt-get update && apt-get upgrade -y'


# -----------------------------------------------------------------------------
# SELKIES DOWNLOAD AT BUILD TIME.
# Done HERE - BEFORE the DNS/resolvconf block - on purpose: that block purges
# systemd-resolved and swaps /etc/resolv.conf for a resolvconf symlink, which
# can break name resolution inside the libguestfs appliance. At this point the
# base image still has working DNS, so curl/wget succeed.
# virt-customize has outgoing network during build (libguestfs appliance),
# so the tarball is fetched now and baked into the image - nothing on firstboot.
# jq + curl are needed for the GitHub API lookup; install them first.
# -----------------------------------------------------------------------------
echo "[SELKIE] Install fetch deps (jq, curl) early for build-time download"
virt-customize -a $FILE_PATH --install jq,curl

echo "[SELKIE] Download + unpack Selkies portable build into ${DESKTOP_HOME} (build time)"
virt-customize -a $FILE_PATH \
  --run-command "set -eu; \
    SELKIES_VERSION=\"\$(curl -fsSL 'https://api.github.com/repos/selkies-project/selkies/releases/latest' | jq -r '.tag_name' | sed 's/[^0-9.\\-]*//g')\"; \
    echo \"Baking Selkies v\${SELKIES_VERSION} into image\"; \
    mkdir -p ${DESKTOP_HOME}; \
    cd ${DESKTOP_HOME}; \
    curl -fsSL \"https://github.com/selkies-project/selkies/releases/download/v\${SELKIES_VERSION}/selkies-gstreamer-portable-v\${SELKIES_VERSION}_amd64.tar.gz\" | tar -xzf -; \
    echo \"\${SELKIES_VERSION}\" > /opt/selkies_version 2>/dev/null || true"
# Ownership is fixed AFTER the desktop user is created (see [USER] block, chown).
echo "[    OK] Selkies baked into image"


echo "[   APT] Uninstall some libs"
virt-customize -a $FILE_PATH --uninstall netplan.io
virt-customize -a $FILE_PATH --run-command 'apt-get purge -y docker.io containerd runc php* systemd-resolved'
virt-customize -a $FILE_PATH --run-command 'apt-get autoremove -y'
virt-customize -a $FILE_PATH --run-command 'dpkg --configure -a'

echo "[   DNS] Use resolvconf for /etc/resolv.conf (ifupdown/eni dns-nameservers + dhcpcd)"
virt-customize -a $FILE_PATH --install resolvconf
virt-customize -a $FILE_PATH --link /run/resolvconf/resolv.conf:/etc/resolv.conf
# The symlink MUST be set via --link (libguestfs swaps /etc/resolv.conf during --run-command).


echo "[   APT] Install basic tools"
virt-customize -a $FILE_PATH --install ifenslave,unzip,zip,mc,screen,gcc,make,wget,curl,telnet,traceroute,tcptraceroute,sudo,gnupg,ca-certificates,nfs-common,aria2,qemu-utils

echo "[   APT] Install basic tools - part 2"
virt-customize -a $FILE_PATH --install nano,bzip2,rsync,openssh-server,apt-transport-https,gpg,htop,jq,yq,psmisc

echo "[   APT] Install basic tools - part 3"
virt-customize -a $FILE_PATH --install virtiofsd,net-tools,sysstat,iproute2,dialog,ethtool,cron


# -----------------------------------------------------------------------------
# DESKTOP: minimal XFCE4 + X11 + Xvfb. Deliberately NO desktop-base, NO
# xfce4-goodies, NO games, NO office suite.
# Using native --install (NOT apt-get in --run-command): --install aborts the
# build on failure, so a broken package list can never silently produce an
# image without a desktop (the earlier failure mode: 'startxfce4: command not
# found' at runtime because an apt-get error in --run-command was swallowed).
# -----------------------------------------------------------------------------
echo "[  DESK] Install minimal X11 stack + Xvfb (Selkies needs X.Org, NOT Wayland)"
virt-customize -a $FILE_PATH --install \
  xserver-xorg-core,xinit,xvfb,dbus-x11,x11-utils,x11-xkb-utils,x11-xserver-utils,x11-apps,x11vnc
# x11vnc - exposes the SAME Xvfb :99 over VNC (shared with Selkies), localhost-only

echo "[  DESK] Install lightweight XFCE4 core (no goodies, no extras)"
virt-customize -a $FILE_PATH --install \
  xfce4-session,xfwm4,xfdesktop4,xfce4-panel,xfce4-settings,xfce4-terminal,thunar,mousepad
# xfce4-session/xfwm4/xfdesktop4/xfce4-panel/xfce4-settings - minimal usable XFCE
# xfce4-terminal - terminal emulator
# thunar         - file manager
# mousepad       - simple text editor (package name is lowercase)

echo "[  WEB ] Install Chromium browser (native Debian package; NOT Google Chrome)"
virt-customize -a $FILE_PATH --install chromium
# Debian package name is 'chromium' (verified, trixie). Native deb -> security
# updates via standard Debian channels, no external Google repo to maintain.

echo "[   SSL] Install ssl-cert (auto-generates the self-signed snakeoil cert+key)"
virt-customize -a $FILE_PATH --install ssl-cert
# Installing ssl-cert generates, based on hostname:
#   /etc/ssl/certs/ssl-cert-snakeoil.pem  (certificate)
#   /etc/ssl/private/ssl-cert-snakeoil.key (private key, group ssl-cert, mode 0640)
# Selkies points at these for HTTPS (see start-selkies.sh, --https_cert/--https_key).
# Note: the cert is bound to hostname, NOT the VM IP -> the browser will still
# show a self-signed warning when reaching it by IP. That is expected; it only
# affects trust prompts, not encryption or the clipboard-over-HTTPS feature.


# -----------------------------------------------------------------------------
# DESKTOP USER: Selkies must run as a non-root user with an active X session.
# -----------------------------------------------------------------------------
if [ "$DESKTOP_USER" = "root" ]; then
  echo "[  USER] DESKTOP_USER=root -> skip user creation; root already exists (HOME=/root)"
  # root is already in every group and reads the snakeoil key directly; the baked
  # Selkies tree under /root is already root-owned. Nothing to create here.
else
  echo "[  USER] Create desktop user '${DESKTOP_USER}' (passwordless sudo, no root login for desktop)"
  virt-customize -a $FILE_PATH \
    --run-command "useradd -m -s /bin/bash ${DESKTOP_USER} || true" \
    --run-command "cp -n /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout /home/${DESKTOP_USER}/ 2>/dev/null || true" \
    --run-command "echo '${DESKTOP_USER}:${DESKTOP_PASSWORD}' | chpasswd" \
    --run-command "usermod -aG sudo ${DESKTOP_USER}" \
    --run-command "echo '${DESKTOP_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${DESKTOP_USER} && chmod 0440 /etc/sudoers.d/${DESKTOP_USER}" \
    --run-command "usermod -aG ssl-cert ${DESKTOP_USER}" \
    --run-command "chown -R ${DESKTOP_USER}:${DESKTOP_USER} /home/${DESKTOP_USER}"
fi
# chown covers the Selkies tree baked in earlier (it was unpacked before the
# user existed, so it is root-owned until now).
# ssl-cert group membership: the snakeoil private key is mode 0640 root:ssl-cert,
# so the non-root Selkies user needs this group to read it for HTTPS.
# NOPASSWD sudoers drop-in (/etc/sudoers.d/${DESKTOP_USER}, mode 0440): the desktop
# user runs sudo without being prompted for a password.


# =============================================================================
# THREE INDEPENDENT SERVICES (decoupled architecture):
#
#   xfce-session.service  -> owns the desktop: starts Xvfb :99 + XFCE.
#                            This is the FOUNDATION; it boots on its own.
#   selkies.service       -> attaches to the existing :99 (WebRTC stream).
#   x11vnc.service        -> attaches to the existing :99 (VNC, localhost).
#
# Neither Selkies nor VNC owns the display anymore, so you can connect via
# VNC first (or only), stop/restart either client service independently, and
# the desktop survives. Both clients depend on the desktop being up.
# =============================================================================

# -----------------------------------------------------------------------------
# 1) DESKTOP: Xvfb :99 + XFCE session. The display lives here, not in Selkies.
# -----------------------------------------------------------------------------
echo "[  DESK] Stage desktop start script (Xvfb :99 + XFCE)"
virt-customize -a $FILE_PATH --run-command "mkdir -p /opt/selkies"

render_tpl start-desktop.sh.tpl start-desktop.sh '${SELKIES_RES}'
virt-customize -a $FILE_PATH \
  --copy-in "${BUILD_TMP}/start-desktop.sh:/opt/selkies" \
  --run-command "chmod +x /opt/selkies/start-desktop.sh"

echo "[  DESK] Stage xfce-session.service"
render_tpl xfce-session.service.tpl xfce-session.service '${DESKTOP_USER}'
# Rewrite /home/<user> -> $DESKTOP_HOME (no-op for normal users; -> /root for root).
sed -i "s#/home/${DESKTOP_USER}#${DESKTOP_HOME}#g" "${BUILD_TMP}/xfce-session.service"
virt-customize -a $FILE_PATH \
  --copy-in "${BUILD_TMP}/xfce-session.service:/etc/systemd/system"


# -----------------------------------------------------------------------------
# 2) SELKIES: attaches to the existing :99 (does NOT start Xvfb/XFCE anymore).
# -----------------------------------------------------------------------------
echo "[SELKIE] Stage Selkies start script (attaches to :99)"
render_tpl start-selkies.sh.tpl start-selkies.sh '${SELKIES_USER} ${SELKIES_PASSWORD}'
virt-customize -a $FILE_PATH \
  --copy-in "${BUILD_TMP}/start-selkies.sh:/opt/selkies" \
  --run-command "chmod +x /opt/selkies/start-selkies.sh" \
  --run-command "chown -R ${DESKTOP_USER}:${DESKTOP_USER} /opt/selkies"

echo "[SELKIE] Stage selkies.service (depends on desktop)"
render_tpl selkies.service.tpl selkies.service '${DESKTOP_USER}'
sed -i "s#/home/${DESKTOP_USER}#${DESKTOP_HOME}#g" "${BUILD_TMP}/selkies.service"
if [ "$DESKTOP_USER" = "root" ]; then
  # Selkies' audio pipeline is MANDATORY (its failure aborts the video stream,
  # leaving the browser on "Waiting for stream"). Order after the system
  # PulseAudio (created in the [ROOT] block) and point pulsesrc at its socket.
  sed -i '/^\[Unit\]/a After=pulseaudio-system.service' "${BUILD_TMP}/selkies.service"
  sed -i '/^\[Service\]/a Environment=PULSE_SERVER=unix:/run/pulse/native' "${BUILD_TMP}/selkies.service"
fi
virt-customize -a $FILE_PATH \
  --copy-in "${BUILD_TMP}/selkies.service:/etc/systemd/system"


# -----------------------------------------------------------------------------
# 3) VNC: x11vnc on the SAME :99 (shared desktop), localhost only.
# - Bound to localhost (-localhost): no direct network exposure.
#   Access via SSH tunnel: ssh -L 5900:127.0.0.1:5900 ${DESKTOP_USER}@<VM>
# - Separate VNC password (-rfbauth), independent of the Linux account password.
# - Depends on the DESKTOP, not on Selkies -> you can connect via VNC FIRST,
#   with Selkies stopped entirely.
# -----------------------------------------------------------------------------
echo "[   VNC] Create VNC password file for ${DESKTOP_USER}"
virt-customize -a $FILE_PATH \
  --run-command "mkdir -p ${DESKTOP_HOME}/.vnc" \
  --run-command "x11vnc -storepasswd '${VNC_PASSWORD}' ${DESKTOP_HOME}/.vnc/passwd" \
  --run-command "chown -R ${DESKTOP_USER}:${DESKTOP_USER} ${DESKTOP_HOME}/.vnc" \
  --run-command "chmod 600 ${DESKTOP_HOME}/.vnc/passwd"

echo "[   VNC] Stage x11vnc.service (depends on desktop, localhost-only)"
render_tpl x11vnc.service.tpl x11vnc.service '${DESKTOP_USER}'
sed -i "s#/home/${DESKTOP_USER}#${DESKTOP_HOME}#g" "${BUILD_TMP}/x11vnc.service"
virt-customize -a $FILE_PATH \
  --copy-in "${BUILD_TMP}/x11vnc.service:/etc/systemd/system"


# =============================================================================
# ROOT CORNER CASE -- only when DESKTOP_USER=root. Fixes the two things that
# break a root desktop (learned the hard way on a live box):
#   1) PulseAudio: root cannot run a per-user daemon, and Selkies ALWAYS opens an
#      audio pipeline on connect. With no PulseAudio that pipeline fails to reach
#      PLAYING, which aborts the session BEFORE the video pipeline starts -> the
#      browser hangs on "Waiting for stream". A system-mode daemon with a dummy
#      null sink (no hardware needed) satisfies it; selkies.service already got
#      PULSE_SERVER + After= above so pulsesrc talks to it.
#   2) Chromium refuses to launch as root without --no-sandbox.
# =============================================================================
if [ "$DESKTOP_USER" = "root" ]; then
  echo "[  ROOT] System PulseAudio + virtual sink (selkies audio is mandatory)"
  virt-customize -a $FILE_PATH --install pulseaudio,pulseaudio-utils
  virt-customize -a $FILE_PATH \
    --run-command "usermod -aG pulse-access root" \
    --run-command "grep -q virtual-speaker /etc/pulse/system.pa || printf '\n# selkies headless capture\nload-module module-null-sink sink_name=virtual-speaker sink_properties=device.description=virtual-speaker\nset-default-sink virtual-speaker\nset-default-source virtual-speaker.monitor\n' >> /etc/pulse/system.pa"

  echo "[  ROOT] Stage pulseaudio-system.service (daemon drops to the 'pulse' user)"
  cat > "${BUILD_TMP}/pulseaudio-system.service" <<'EOF'
[Unit]
Description=PulseAudio system daemon (root desktop image, selkies)
After=network.target

[Service]
ExecStart=/usr/bin/pulseaudio --system --disallow-exit --log-target=journal
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  virt-customize -a $FILE_PATH \
    --copy-in "${BUILD_TMP}/pulseaudio-system.service:/etc/systemd/system" \
    --run-command "systemctl enable pulseaudio-system.service"

  echo "[  ROOT] Chromium --no-sandbox drop-in (required to launch chromium as root)"
  virt-customize -a $FILE_PATH \
    --run-command "mkdir -p /etc/chromium.d" \
    --run-command "printf 'export CHROMIUM_FLAGS=\"\$CHROMIUM_FLAGS --no-sandbox --test-type\"\n' > /etc/chromium.d/00-no-sandbox"
fi


echo "[  MOTD] Stage live login banner (/etc/update-motd.d/99-motd-update)"
render_tpl 99-motd-update.tpl 99-motd-update '${DESKTOP_USER} ${SELKIES_USER}'
virt-customize -a $FILE_PATH \
  --copy-in "${BUILD_TMP}/99-motd-update:/etc/update-motd.d" \
  --run-command "chmod 0755 /etc/update-motd.d/99-motd-update"
# Live MOTD: pam_motd runs /etc/update-motd.d/* on each login and caches to
# /run/motd.dynamic, so the IP is resolved fresh per login. Named motd-update.


# Enable all three at build time (baked-in Selkies needs no firstboot fetch).
echo "[   SVC] Enable desktop + selkies + x11vnc services"
virt-customize -a $FILE_PATH \
  --run-command 'systemctl enable xfce-session.service selkies.service x11vnc.service'


echo "[ NETUI] Download netui TUI into image"
curl -fsSL "${LINUX4U_REPO}/bin/netui" -o "${BUILD_TMP}/netui" \
  || { echo "[  FAIL] fetch netui"; exit 1; }
virt-customize -a $FILE_PATH \
  --copy-in "${BUILD_TMP}/netui:/usr/local/bin" \
  --run-command 'chmod 0755 /usr/local/bin/netui'
echo "[    OK] /usr/local/bin/netui - installed"

echo "[DESKUI] Download deskui TUI into image"
curl -fsSL "${LINUX4U_REPO}/bin/deskui" -o "${BUILD_TMP}/deskui" \
  || { echo "[  FAIL] fetch deskui"; exit 1; }
virt-customize -a $FILE_PATH \
  --copy-in "${BUILD_TMP}/deskui:/usr/local/bin" \
  --run-command 'chmod 0755 /usr/local/bin/deskui'
echo "[    OK] /usr/local/bin/deskui - installed"


echo "[  WAIT] Mask systemd-networkd-wait-online (networkd is not the manager)"
virt-customize -a $FILE_PATH --run-command 'systemctl mask systemd-networkd-wait-online.service'


echo "[   SSH] Set sshd allow ranges"
virt-customize -a $FILE_PATH \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.deny; echo 'sshd: ALL' >> /etc/hosts.deny" \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.allow; echo 'sshd: 10.0.0.0/8\nsshd: 172.16.0.0/12\nsshd: 192.168.0.0/16\n' >> /etc/hosts.allow"


echo "[ GUEST] Install guest agents"
virt-customize -a $FILE_PATH --install qemu-guest-agent,open-vm-tools


# Fix .bashrc to enable colors and aliases (root + desktop user).
# NOTE: the /etc/skel .bashrc (seeded for ${DESKTOP_USER}) differs from root's:
# 'ls --color' is already active in the dircolors block, so for the user we only
# enable the colored prompt and the ll/la/l aliases (skel uses '#alias', no space).
echo "[BASHRC] Fix root + ${DESKTOP_USER} .bashrc to enable colors and aliases"
virt-customize -a $FILE_PATH \
    --run-command "sed -i 's/^# export LS_OPTIONS=/export LS_OPTIONS=/' /root/.bashrc" \
    --run-command "sed -i 's/^# eval /eval /' /root/.bashrc" \
    --run-command "sed -i 's/^# alias ls=/alias ls=/' /root/.bashrc" \
    --run-command "sed -i 's/^# alias ll=/alias ll=/' /root/.bashrc" \
    --run-command "sed -i 's/^# alias l=/alias l=/' /root/.bashrc"
# The /etc/skel-seeded .bashrc tweaks only apply to a normal user's home; for
# DESKTOP_USER=root the desktop home IS /root, already handled just above.
if [ "$DESKTOP_USER" != "root" ]; then
  virt-customize -a $FILE_PATH \
    --run-command "sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /home/${DESKTOP_USER}/.bashrc" \
    --run-command "sed -i 's/^#alias ll=/alias ll=/' /home/${DESKTOP_USER}/.bashrc" \
    --run-command "sed -i 's/^#alias la=/alias la=/' /home/${DESKTOP_USER}/.bashrc" \
    --run-command "sed -i 's/^#alias l=/alias l=/' /home/${DESKTOP_USER}/.bashrc"
fi


# Create QuickScript folder
fetch_base download_scripts.sh download_scripts.sh
fetch_base quick_upgrade.sh quick_upgrade.sh
virt-customize -a $FILE_PATH \
    --run-command 'mkdir -p /opt/scripts' \
    --copy-in "${BUILD_TMP}/download_scripts.sh:/opt/scripts" \
    --copy-in "${BUILD_TMP}/quick_upgrade.sh:/opt/scripts" \
    --run-command 'chmod +x /opt/scripts/download_scripts.sh /opt/scripts/quick_upgrade.sh'
echo "[    OK] /opt/scripts - created inside image"


# -----------------------------------------------------------------------------
# FIRSTBOOT: regen ssh host keys, enable ssh, install Selkies (needs network),
# enable the Selkies service. apt-daily timers disabled to avoid boot races.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# FIRSTBOOT: only regen ssh host keys + enable ssh + disable apt-daily timers.
# Selkies is already baked in and its service already enabled at build time,
# so NOTHING Selkies-related needs the network on first boot.
# -----------------------------------------------------------------------------
echo "[    ..] Configure firstboot commands"
virt-customize -a $FILE_PATH \
  --firstboot-command 'ssh-keygen -A && systemctl enable ssh && systemctl restart ssh && systemctl disable --now apt-daily.timer apt-daily-upgrade.timer'
echo "[    OK] firstboot configured"


# Check if we are on proxmox
if [ -d "/var/lib/vz/import/" ]; then
    echo "[    ..] Copy image to proxmox"
    cp $FILE_PATH /var/lib/vz/import/
    if [ -n "$FINAL_NAME" ]; then
        mv /var/lib/vz/import/$FILE_PATH /var/lib/vz/import/$FINAL_NAME
    fi
    echo "[    OK] Copy image to proxmox /var/lib/vz/import/ - done"
else
    echo "[    OK] No Proxmox detected - skipped copy image to proxmox /var/lib/vz/import/"
fi

if [ "$KEEP_FILE" = "true" ]; then
    echo "[    OK] Cleanup skipped"
else
    echo "[    OK] Cleanup"
    rm $FILE_PATH
fi
exit 0