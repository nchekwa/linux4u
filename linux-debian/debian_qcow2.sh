#!/bin/sh

ROOT_PASSWORD="root"
TIMEZONE="UTC"
DEBUG="${DEBUG:-false}"
FINAL_NAME="${FINAL_NAME:-$FILE_PATH}"

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
    FINAL_NAME="debian-${VERSION}-generic-amd64.qcow2"
    echo "Final name: $FINAL_NAME"
else
    FINAL_NAME="$FILE_PATH"
    echo "Final name: $FINAL_NAME"
fi


# ### Set Debug in case of troubelshooting
if [ "$DEBUG" = "true" ]; then
    export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
fi


echo "[    ..] Install local tools nessesery to run virt..."
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


echo "[  DISK] - increase sda disk to 10G (original is ~2.2GB)"
qemu-img resize $FILE_PATH 10G 
echo "[  DISK] - change sda1 partition size"
virt-customize -a $FILE_PATH --run-command "growpart /dev/sda 1 &&  resize2fs /dev/sda1"
# virt-filesystems --long --parts --blkdevs -h -a $file_path

echo "[   NET] - set net.ifnames=0 biosdevname=0"
virt-customize -a $FILE_PATH \
  --edit '/etc/default/grub:s/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 /' \
  --run-command 'update-grub'

echo "[   NET] - make cloud-init render network via NetworkManager (so Proxmox cloud-init IP+DNS land in NM -> /etc/resolv.conf)"
virt-customize -a $FILE_PATH \
  --run-command 'mkdir -p /etc/cloud/cloud.cfg.d && cat << EOF > /etc/cloud/cloud.cfg.d/99-network-manager.cfg
system_info:
  network:
    renderers: ["network-manager"]
EOF'
# cloud-init by default renders via netplan -> systemd-networkd. With NetworkManager as the
# single stack we must force the network-manager renderer, otherwise the DNS that cloud-init
# (Proxmox datasource / DHCP) obtains never reaches /etc/resolv.conf. The renderer key is read
# from system_info (cloudinit Distro._cfg == system_info block) - a top-level 'network:' is ignored.




echo "[   APT] Add agent to image"
virt-customize -a $FILE_PATH --run-command 'apt-get update && apt-get upgrade -y'


echo "[   APT] Uninstall some libs"
virt-customize -a $FILE_PATH --run-command 'apt-get purge -y docker.io containerd runc php*'
virt-customize -a $FILE_PATH --run-command 'apt-get autoremove -y'
virt-customize -a $FILE_PATH --run-command 'dpkg --configure -a'


echo "[   APT] Install basic tools"
virt-customize -a $FILE_PATH --install ifenslave,unzip,zip,mc,screen,gcc,make,wget,curl,telnet,traceroute,tcptraceroute,sudo,gnupg,ca-certificates,nfs-common,aria2,qemu-utils
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
virt-customize -a $FILE_PATH --install nano,bzip2,rsync,openssh-server,apt-transport-https,gpg,htop,jq,yq,psmisc
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
virt-customize -a $FILE_PATH --install virtiofsd,net-tools,sysstat,iproute2
# virtiofsd - Virtiofs is a shared filesystem designed for virtual environments


echo "[  NMTUI] Install NetworkManager for TUI network configuration"
virt-customize -a $FILE_PATH --install network-manager
# network-manager - provides nmtui for easy network configuration

echo "[    NM] Let NetworkManager manage ifupdown interfaces (fix 'device strictly unmanaged')"
virt-customize -a $FILE_PATH \
  --run-command "sed -i 's/^managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf"
# Debian's network-manager package ships [ifupdown] managed=false, which makes NM
# deliberately ignore interfaces known to ifupdown (e.g. eth0) and can leave eth0
# 'strictly unmanaged'. Forcing managed=true ensures NetworkManager takes over the
# interface (cloud-init writes NM keyfiles directly via the network-manager renderer).


echo "[   SSH] Set sshd to allow all"
virt-customize -a $FILE_PATH \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.deny; echo 'sshd: ALL' >> /etc/hosts.deny" \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.allow; echo 'sshd: 10.0.0.0/8\nsshd: 172.16.0.0/12\nsshd: 192.168.0.0/16\n' >> /etc/hosts.allow"


echo "[ GUEST] Install guest agents"
virt-customize -a $FILE_PATH --install qemu-guest-agent,open-vm-tools
# qemu-guest-agent - allow support guest agent
# open-vm-tools - allow support vmware tools


echo "[  MOTD] Add network configuration notice"
virt-customize -a $FILE_PATH \
  --run-command 'mkdir -p /etc/update-motd.d' \
  --run-command 'cat << EOF > /etc/update-motd.d/99-network-notice
#!/bin/sh
echo ""
echo "  ╔════════════════════════════════════════════════════════════╗"
echo "  ║  To configure IP address, run:                              ║"
echo "  ║                                                            ║"
echo "  ║      sudo nmtui                                            ║"
echo "  ║                                                            ║"
echo "  ║  Or manually edit netplan:                                 ║"
echo "  ║      sudo nano /etc/netplan/*.yaml && sudo netplan apply   ║"
echo "  ╚════════════════════════════════════════════════════════════╝"
echo ""
EOF' \
  --run-command 'chmod +x /etc/update-motd.d/99-network-notice'


# Fix .bashrc to enable colors and aliases
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
    --run-command 'cat << EOF > /opt/scripts/download_scripts.sh
#!/bin/bash
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_docker.sh -O /opt/scripts/install_docker.sh
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_mise.sh -O /opt/scripts/install_mise.sh
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_npm.sh -O /opt/scripts/install_npm.sh
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_opentofu.sh -O /opt/scripts/install_opentofu.sh
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_pulumi.sh -O /opt/scripts/install_pulumi.sh
chmod +x /opt/scripts/*.sh
EOF' \
    --run-command 'chmod +x /opt/scripts/download_scripts.sh' \
    --run-command 'cat << EOF > /opt/scripts/quick_upgrade.sh
#!/bin/bash
apt-get update && apt-get upgrade -y && apt-get dist-upgrade -y && apt-get autoremove -y && apt-get autoclean -y
EOF' \
    --run-command 'chmod +x /opt/scripts/quick_upgrade.sh'
echo "[    OK] /opt/scripts - created inside image"



echo "[    ..] Add ssh-keygen -A to firstboot and enable NetworkManager"
virt-customize -a $FILE_PATH --firstboot-command 'ssh-keygen -A && systemctl enable ssh && systemctl restart ssh && systemctl enable NetworkManager && systemctl start NetworkManager && systemctl disable --now apt-daily.timer apt-daily-upgrade.timer'
echo "[    OK] Add ssh-keygen -A to firstboot - done"

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