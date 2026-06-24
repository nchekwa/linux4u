#!/bin/sh

ROOT_PASSWORD="root"
TIMEZONE="UTC"
DEBUG="${DEBUG:-false}"
# Shared payloads (linux-debian/base/) are fetched from the repo at build time, so this
# builder stays a single downloadable file. Pin LINUX4U_REF to a tag/SHA for reproducible builds.
LINUX4U_REF="${LINUX4U_REF:-main}"
LINUX4U_REPO="https://raw.githubusercontent.com/nchekwa/linux4u/${LINUX4U_REF}"

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
if [ -z "${FINAL_NAME:-}" ]; then
    FINAL_NAME="debian-${VERSION}-generic-amd64-cloud-init.qcow2"
fi
echo "Final name: $FINAL_NAME"


# ### Set Debug in case of troubelshooting
if [ "$DEBUG" = "true" ]; then
    export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
fi


echo "[    ..] Install local tools nessesery to run virt..."
sudo apt update -y && sudo apt install nano wget curl libguestfs-tools libvirt-login-shell 7zip -y


# -----------------------------------------------------------------------------
# Payload fetch helper. curl runs on the HOST (not inside the libguestfs appliance),
# so it is unaffected by the build-time DNS swap done by the [DNS] block; fetched files
# are injected with virt-customize --copy-in. Shared payloads live in linux-debian/base/.
# -----------------------------------------------------------------------------
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT

fetch_base() {
  # $1 = filename in linux-debian/base/, $2 = output name in BUILD_TMP
  curl -fsSL "${LINUX4U_REPO}/linux-debian/base/$1" -o "${BUILD_TMP}/$2" \
    || { echo "[  FAIL] fetch base $1"; exit 1; }
}


echo "[   ISO] Download Debian img if not exist"
if [ ! -e "$FILE_PATH" ]; then
    echo "[    ..] File does not exist. Downloading..."
    wget -O "$FILE_PATH" "$URL" || { echo "[  FAIL] download failed"; rm -f "$FILE_PATH"; exit 1; }
else
    echo "[    OK] File already exists."
fi


echo "[    TZ] set timezone UTC"
virt-customize -a "$FILE_PATH" --timezone $TIMEZONE

echo "[  ROOT] set root password"
virt-customize -a "$FILE_PATH" --root-password password:$ROOT_PASSWORD

echo "[   SSH] enable password auth to yes"
virt-customize -a "$FILE_PATH" --run-command 'sed -i s/^PasswordAuthentication.*/PasswordAuthentication\ yes/ /etc/ssh/sshd_config'
echo "[   SSH] allow root login with ssh-key only"
virt-customize -a "$FILE_PATH" --run-command 'sed -i s/^#PermitRootLogin.*/PermitRootLogin\ yes/ /etc/ssh/sshd_config'


echo "[  DISK] - increase sda disk to 10G (original is ~2.2GB)"
qemu-img resize "$FILE_PATH" 10G
echo "[  DISK] - change sda1 partition size"
virt-customize -a "$FILE_PATH" --run-command "growpart /dev/sda 1 &&  resize2fs /dev/sda1"
# virt-filesystems --long --parts --blkdevs -h -a $file_path

echo "[   NET] - set net.ifnames=0 biosdevname=0"
virt-customize -a "$FILE_PATH" \
  --edit '/etc/default/grub:s/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 /' \
  --run-command 'update-grub'

echo "[   NET] - make cloud-init render network via ifupdown (eni renderer)"
fetch_base 99-eni.cfg 99-eni.cfg
virt-customize -a "$FILE_PATH" \
  --run-command 'mkdir -p /etc/cloud/cloud.cfg.d' \
  --copy-in "${BUILD_TMP}/99-eni.cfg:/etc/cloud/cloud.cfg.d"
# Unify on ifupdown: force cloud-init to render to /etc/network/interfaces(.d) via the eni renderer
# instead of netplan/network-manager. The renderer key is read from system_info (cloudinit
# Distro._cfg == system_info block) - a top-level 'network:' is ignored. DNS is handled by
# resolvconf (systemd-resolved removed below); see the [DNS] block.

echo "[   NET] - pre-seed eth0 DHCP default for boots with no cloud-init datasource"
fetch_base 50-cloud-init 50-cloud-init
virt-customize -a "$FILE_PATH" \
  --run-command 'mkdir -p /etc/network/interfaces.d' \
  --copy-in "${BUILD_TMP}/50-cloud-init:/etc/network/interfaces.d"
# Debian ds-identify DISABLES cloud-init when no datasource is found (default policy
# notfound=disabled), and genericcloud ships no static eth0 - so a VM booted WITHOUT a
# cloud-init drive would render nothing and eth0 would stay "qdisc noop state DOWN".
# Pre-seeding cloud-init's own eni render path (/etc/network/interfaces.d/50-cloud-init) with a
# plain IPv4 DHCP stanza fixes this with a SINGLE file (no extra service, no duplicate eth0
# stanza): cloud-init OVERWRITES this file when a datasource IS present (verified: a
# datasource-provided static IP is applied cleanly, no leftover DHCP), and leaves it untouched
# when disabled (eth0 comes up on DHCP; dhcpcd handles IPv6 via RA). Forcing cloud-init on via
# ds-identify notfound=enabled was rejected: it triggers ~240s EC2 IMDS probing AND cloud-init
# hardcodes a dual-stack fallback whose 'inet6 dhcp' line fails on this dhcpcd-based image.
# Verified on live qemu/KVM VMs both WITH and WITHOUT a datasource. See docs/notes/learnings.


echo "[   APT] Add agent to image"
virt-customize -a "$FILE_PATH" --run-command 'apt-get update && apt-get upgrade -y'


echo "[   APT] Uninstall some libs"
virt-customize -a "$FILE_PATH" --uninstall netplan.io
virt-customize -a "$FILE_PATH" --run-command 'apt-get purge -y docker.io containerd runc php* systemd-resolved'
virt-customize -a "$FILE_PATH" --run-command 'apt-get autoremove -y'
virt-customize -a "$FILE_PATH" --run-command 'dpkg --configure -a'

echo "[   DNS] Use resolvconf for /etc/resolv.conf (ifupdown/eni dns-nameservers + dhcpcd)"
virt-customize -a "$FILE_PATH" --install resolvconf
virt-customize -a "$FILE_PATH" --link /run/resolvconf/resolv.conf:/etc/resolv.conf
# systemd-resolved is purged: its if-up hook (/etc/network/if-up.d/resolved) exempts the loopback
# interface, and cloud-init's eni renderer places dns-nameservers on lo -> DNS lost. resolvconf
# DOES capture those (verified live: "resolv.conf from lo.inet") and has no lo exemption.
# The symlink MUST be set via --link, NOT --run-command: libguestfs swaps /etc/resolv.conf for
# appliance networking during --run-command/--install and restores the original (the dead
# systemd-resolved stub) afterwards, which would revert an in-guest 'ln -sf'.
# Verified on a live VM (Proxmox-style cloud-init): /etc/resolv.conf shows the datasource nameservers.


echo "[   APT] Install basic tools"
virt-customize -a "$FILE_PATH" --install ifenslave,unzip,zip,mc,screen,gcc,make,wget,curl,telnet,traceroute,tcptraceroute,sudo,gnupg,ca-certificates,nfs-common,aria2,qemu-utils
# ifenslave - allow to use ifconfig
# unzip - allow support unzip ZIP files
# zip - allow support zip ZIP files
# mc - allow support Midnight Commander
# screen - allow support screen
# gcc, make - allow support compilation
# wget, curl - allow support download
# telnet, traceroute, tcptraceroute - allow support network tools
# sudo - allow support sudo
# gnupg, ca-certificates - allow support gpg
# nfs-common - allow support nfs
# aria2 - allow support aria2
# qemu-utils - allow support qemu

echo "[   APT] Install basic tools - part 2"
virt-customize -a "$FILE_PATH" --install nano,bzip2,rsync,openssh-server,apt-transport-https,gpg,htop,jq,yq,psmisc
# nano - edit files by nano
# bzip2 - allow support bzip2
# rsync - allow synchronisation files rsync
# openssh-server - allow support ssh      -> ssh-keygen -A
# apt-transport-https - allow support apt-transport-https
# gpg - allow support gpg
# htop - allow monitoring system stats by htop 
# jq - allow support jq (decode in CLI JSON)
# yq - allow support yq (decode in CLI YAML)
# psmisc - allow support killall command

echo "[   APT] Install basic tools - part 3"
virt-customize -a "$FILE_PATH" --install virtiofsd,net-tools,sysstat,iproute2,dialog,ethtool,cron
# virtiofsd - Virtiofs is a shared filesystem designed for virtual environments
# dialog  - required by the netui TUI (netui dies if missing)
# ethtool   - used by netui status report (link/speed/SFP); sysfs fallback otherwise
# cron      - provides /etc/crontab + cron daemon (not in Debian genericcloud by default)


echo "[ NETUI] Download netui TUI into image"
curl -fsSL "${LINUX4U_REPO}/bin/netui" -o "${BUILD_TMP}/netui" \
  || { echo "[  FAIL] fetch netui"; exit 1; }
virt-customize -a "$FILE_PATH" \
  --copy-in "${BUILD_TMP}/netui:/usr/local/bin" \
  --run-command 'chmod 0755 /usr/local/bin/netui'
echo "[    OK] /usr/local/bin/netui - installed"


echo "[  WAIT] Mask systemd-networkd-wait-online (networkd is not the manager; avoids ~120s boot hang)"
virt-customize -a "$FILE_PATH" --run-command 'systemctl mask systemd-networkd-wait-online.service'
# systemd-networkd-wait-online.service is enabled by the genericcloud preset with the default
# 120s timeout. Since networking is managed by ifupdown (cloud-init renders via the eni renderer),
# systemd-networkd manages no links, so this waiter never sees an "online" link and blocks
# network-online.target for the full 120s on every boot (confirmed on a live VM via
# 'systemd-analyze blame': "2min systemd-networkd-wait-online.service").


echo "[   SSH] Set sshd to allow all"
virt-customize -a "$FILE_PATH" \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.deny; echo 'sshd: ALL' >> /etc/hosts.deny" \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.allow; echo 'sshd: 10.0.0.0/8\nsshd: 172.16.0.0/12\nsshd: 192.168.0.0/16\nsshd: 100.111.0.0/16\n' >> /etc/hosts.allow"


echo "[ GUEST] Install guest agents"
virt-customize -a "$FILE_PATH" --install qemu-guest-agent,open-vm-tools
# qemu-guest-agent - allow support guest agent
# open-vm-tools - allow support vmware tools


# Fix .bashrc to enable colors and aliases
echo "[BASHRC] Fix root .bashrc to enable colors and aliases"
virt-customize -a "$FILE_PATH" \
    --run-command "sed -i 's/^# export LS_OPTIONS=/export LS_OPTIONS=/' /root/.bashrc" \
    --run-command "sed -i 's/^# eval /eval /' /root/.bashrc" \
    --run-command "sed -i 's/^# alias ls=/alias ls=/' /root/.bashrc" \
    --run-command "sed -i 's/^# alias ll=/alias ll=/' /root/.bashrc" \
    --run-command "sed -i 's/^# alias l=/alias l=/' /root/.bashrc"

# Create QuickScript folder
fetch_base download_scripts.sh download_scripts.sh
fetch_base quick_upgrade.sh quick_upgrade.sh
virt-customize -a "$FILE_PATH" \
    --run-command 'mkdir -p /opt/scripts' \
    --copy-in "${BUILD_TMP}/download_scripts.sh:/opt/scripts" \
    --copy-in "${BUILD_TMP}/quick_upgrade.sh:/opt/scripts" \
    --run-command 'chmod +x /opt/scripts/download_scripts.sh /opt/scripts/quick_upgrade.sh'
echo "[    OK] /opt/scripts - created inside image"



echo "[    ..] Add ssh-keygen -A to firstboot"
virt-customize -a "$FILE_PATH" --firstboot-command 'ssh-keygen -A && systemctl enable ssh && systemctl restart ssh && systemctl disable --now apt-daily.timer apt-daily-upgrade.timer'
echo "[    OK] Add ssh-keygen -A to firstboot - done"

# Check if we are on proxmox
if [ -d "/var/lib/vz/import/" ]; then
    echo "[    ..] Copy image to proxmox"
    cp "$FILE_PATH" /var/lib/vz/import/
    if [ -n "$FINAL_NAME" ]; then
        mv "/var/lib/vz/import/$FILE_PATH" "/var/lib/vz/import/$FINAL_NAME"
    fi
    echo "[    OK] Copy image to proxmox /var/lib/vz/import/ - done"
else
    echo "[    OK] No Proxmox detected - skipped copy image to proxmox /var/lib/vz/import/"
fi

if [ "$KEEP_FILE" = "true" ]; then
    echo "[    OK] Cleanup skipped"
else
    echo "[    OK] Cleanup"
    rm "$FILE_PATH"
fi
exit 0