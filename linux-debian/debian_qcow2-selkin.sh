#!/bin/sh
# debian_qcow2-selkin.sh
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

# Desktop user (Selkies runs as a normal user, NOT root)
DESKTOP_USER="${DESKTOP_USER:-user}"
DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-user}"

# Selkies HTTP basic-auth credentials (web UI login)
SELKIES_USER="${SELKIES_USER:-user}"
SELKIES_PASSWORD="${SELKIES_PASSWORD:-changeme}"
# Streamed virtual display geometry
SELKIES_RES="${SELKIES_RES:-1920x1080}"

# VNC password (separate from the Linux user password; VNC uses its own scheme).
# x11vnc shares the SAME :99 display as Selkies, bound to localhost only.
# Reach it via SSH tunnel:  ssh -L 5900:127.0.0.1:5900 user@VM  then connect a
# VNC viewer to 127.0.0.1:5900.
VNC_PASSWORD="${VNC_PASSWORD:-changeme}"

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
    FINAL_NAME="debian-${VERSION}-selkin-amd64.qcow2"
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
sudo apt update -y && sudo apt install nano wget curl libguestfs-tools libvirt-login-shell 7zip -y


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
virt-customize -a $FILE_PATH \
  --run-command 'mkdir -p /etc/cloud/cloud.cfg.d && cat << EOF > /etc/cloud/cloud.cfg.d/99-eni.cfg
system_info:
  network:
    renderers: ["eni"]
EOF'
# Unify on ifupdown: force cloud-init to render to /etc/network/interfaces(.d) via the eni renderer
# instead of netplan/network-manager. DNS handled by resolvconf (see the [DNS] block).


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

echo "[SELKIE] Download + unpack Selkies portable build into /home/${DESKTOP_USER} (build time)"
virt-customize -a $FILE_PATH \
  --run-command "set -eu; \
    SELKIES_VERSION=\"\$(curl -fsSL 'https://api.github.com/repos/selkies-project/selkies/releases/latest' | jq -r '.tag_name' | sed 's/[^0-9.\\-]*//g')\"; \
    echo \"Baking Selkies v\${SELKIES_VERSION} into image\"; \
    mkdir -p /home/${DESKTOP_USER}; \
    cd /home/${DESKTOP_USER}; \
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
virt-customize -a $FILE_PATH --install virtiofsd,net-tools,sysstat,iproute2,whiptail,ethtool,cron


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
echo "[  USER] Create desktop user '${DESKTOP_USER}' (sudo, no root login for desktop)"
virt-customize -a $FILE_PATH \
  --run-command "useradd -m -s /bin/bash ${DESKTOP_USER} || true" \
  --run-command "echo '${DESKTOP_USER}:${DESKTOP_PASSWORD}' | chpasswd" \
  --run-command "usermod -aG sudo ${DESKTOP_USER}" \
  --run-command "usermod -aG ssl-cert ${DESKTOP_USER}" \
  --run-command "chown -R ${DESKTOP_USER}:${DESKTOP_USER} /home/${DESKTOP_USER}"
# chown covers the Selkies tree baked in earlier (it was unpacked before the
# user existed, so it is root-owned until now).
# ssl-cert group membership: the snakeoil private key is mode 0640 root:ssl-cert,
# so the non-root Selkies user needs this group to read it for HTTPS.


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

virt-customize -a $FILE_PATH \
  --run-command "cat << 'EOF' > /opt/selkies/start-desktop.sh
#!/usr/bin/env bash
# Foundation: a headless virtual X11 display (:99) running an XFCE session.
# Independent of any remote-access client (Selkies / VNC attach to it later).
set -euo pipefail

export DISPLAY=':99'
export XDG_RUNTIME_DIR=\"\${XDG_RUNTIME_DIR:-/tmp}\"
RES='${SELKIES_RES}'

# Virtual X11 framebuffer (no physical monitor / no GPU)
exec_xvfb() {
  Xvfb \"\${DISPLAY}\" -screen 0 \"\${RES}x24\" \
    +extension COMPOSITE +extension DAMAGE +extension GLX +extension RANDR \
    +extension RENDER +extension MIT-SHM +extension XFIXES +extension XTEST \
    -nolisten tcp -ac -noreset >/tmp/Xvfb.log 2>&1 &
}
exec_xvfb

echo 'Waiting for X socket'
until [ -S \"/tmp/.X11-unix/X\${DISPLAY#*:}\" ]; do sleep 0.5; done
echo 'X server ready'

# Run the XFCE session in the FOREGROUND so systemd tracks this unit's liveness
# by the desktop session itself (Type=simple stays active while XFCE runs).
rm -rf \"\${HOME}/.config/xfce4\"
exec startxfce4
EOF" \
  --run-command "chmod +x /opt/selkies/start-desktop.sh"

echo "[  DESK] Stage xfce-session.service"
virt-customize -a $FILE_PATH \
  --run-command "cat << EOF > /etc/systemd/system/xfce-session.service
[Unit]
Description=Headless XFCE desktop on Xvfb :99 (foundation for Selkies + VNC)
After=network.target

[Service]
Type=simple
User=${DESKTOP_USER}
WorkingDirectory=/home/${DESKTOP_USER}
ExecStart=/opt/selkies/start-desktop.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"


# -----------------------------------------------------------------------------
# 2) SELKIES: attaches to the existing :99 (does NOT start Xvfb/XFCE anymore).
# -----------------------------------------------------------------------------
echo "[SELKIE] Stage Selkies start script (attaches to :99)"
virt-customize -a $FILE_PATH \
  --run-command "cat << 'EOF' > /opt/selkies/start-selkies.sh
#!/usr/bin/env bash
# Selkies WebRTC stream, software x264 encoding. Attaches to the already-running
# :99 display owned by xfce-session.service.
set -euo pipefail

export DISPLAY=':99'
export XDG_RUNTIME_DIR=\"\${XDG_RUNTIME_DIR:-/tmp}\"

# Wait until the desktop's :99 socket exists (defensive; systemd ordering also covers this)
until [ -S \"/tmp/.X11-unix/X99\" ]; do sleep 0.5; done

\"\${HOME}/selkies-gstreamer/selkies-gstreamer-run\" \
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
EOF" \
  --run-command "chmod +x /opt/selkies/start-selkies.sh" \
  --run-command "chown -R ${DESKTOP_USER}:${DESKTOP_USER} /opt/selkies"

echo "[SELKIE] Stage selkies.service (depends on desktop)"
virt-customize -a $FILE_PATH \
  --run-command "cat << EOF > /etc/systemd/system/selkies.service
[Unit]
Description=Selkies X11 remote desktop stream (software x264)
After=xfce-session.service
Requires=xfce-session.service
# No network-online.target dependency: this image manages networking via
# ifupdown/eni (not systemd-networkd), so network-online.target is never
# satisfied by a networkd waiter and would stall boot. Selkies only needs the
# desktop (:99) to be up; the listen socket binds regardless of "online" state.

[Service]
Type=simple
User=${DESKTOP_USER}
WorkingDirectory=/home/${DESKTOP_USER}
ExecStart=/opt/selkies/start-selkies.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"


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
  --run-command "mkdir -p /home/${DESKTOP_USER}/.vnc" \
  --run-command "x11vnc -storepasswd '${VNC_PASSWORD}' /home/${DESKTOP_USER}/.vnc/passwd" \
  --run-command "chown -R ${DESKTOP_USER}:${DESKTOP_USER} /home/${DESKTOP_USER}/.vnc" \
  --run-command "chmod 600 /home/${DESKTOP_USER}/.vnc/passwd"

echo "[   VNC] Stage x11vnc.service (depends on desktop, localhost-only)"
virt-customize -a $FILE_PATH \
  --run-command "cat << EOF > /etc/systemd/system/x11vnc.service
[Unit]
Description=x11vnc on shared Xvfb :99 (localhost only)
After=xfce-session.service
Requires=xfce-session.service

[Service]
Type=simple
User=${DESKTOP_USER}
# WAIT:99 - block until the desktop's Xvfb :99 is up, then attach
ExecStart=/usr/bin/x11vnc -display WAIT:99 -rfbauth /home/${DESKTOP_USER}/.vnc/passwd -localhost -shared -forever -rfbport 5900
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"


# Enable all three at build time (baked-in Selkies needs no firstboot fetch).
echo "[   SVC] Enable desktop + selkies + x11vnc services"
virt-customize -a $FILE_PATH \
  --run-command 'systemctl enable xfce-session.service selkies.service x11vnc.service'


echo "[ NETUI] Download netui TUI into image"
virt-customize -a $FILE_PATH \
  --run-command 'wget https://raw.githubusercontent.com/nchekwa/linux4u/refs/heads/main/bin/netui -O /usr/local/bin/netui && chmod 0755 /usr/local/bin/netui'
echo "[    OK] /usr/local/bin/netui - installed"


echo "[  WAIT] Mask systemd-networkd-wait-online (networkd is not the manager)"
virt-customize -a $FILE_PATH --run-command 'systemctl mask systemd-networkd-wait-online.service'


echo "[   SSH] Set sshd allow ranges"
virt-customize -a $FILE_PATH \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.deny; echo 'sshd: ALL' >> /etc/hosts.deny" \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.allow; echo 'sshd: 10.0.0.0/8\nsshd: 172.16.0.0/12\nsshd: 192.168.0.0/16\n' >> /etc/hosts.allow"


echo "[ GUEST] Install guest agents"
virt-customize -a $FILE_PATH --install qemu-guest-agent,open-vm-tools


# Fix root .bashrc to enable colors and aliases
echo "[BASHRC] Fix root .bashrc to enable colors and aliases"
virt-customize -a $FILE_PATH \
    --run-command "sed -i 's/^# export LS_OPTIONS=/export LS_OPTIONS=/' /root/.bashrc" \
    --run-command "sed -i 's/^# eval /eval /' /root/.bashrc" \
    --run-command "sed -i 's/^# alias ls=/alias ls=/' /root/.bashrc" \
    --run-command "sed -i 's/^# alias ll=/alias ll=/' /root/.bashrc" \
    --run-command "sed -i 's/^# alias l=/alias l=/' /root/.bashrc"


# Create QuickScript folder
virt-customize -a $FILE_PATH \
    --run-command 'mkdir -p /opt/scripts' \
    --run-command 'cat << EOF > /opt/scripts/quick_upgrade.sh
#!/bin/bash
apt-get update && apt-get upgrade -y && apt-get dist-upgrade -y && apt-get autoremove -y && apt-get autoclean -y
EOF' \
    --run-command 'chmod +x /opt/scripts/quick_upgrade.sh'
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