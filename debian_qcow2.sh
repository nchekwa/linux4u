#!/bin/sh

ROOT_PASSWORD="root"
TIMEZONE="UTC"
DEBUG="${DEBUG:-false}"
FINAL_NAME="${FINAL_NAME:-$FILE_PATH}"

# Check if version argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <version>"
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
        echo "Invalid version. Supported versions are 20.04, 22.04 and 13."
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



echo "[   ISO] Download UBUNTU img if not exist"
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


echo "[  DISK] - increase sda disk to 100G (original is ~2.2GB)"
qemu-img resize $FILE_PATH +98G 
echo "[  DISK] - change sda1 partition size"
virt-customize -a $FILE_PATH --run-command "growpart /dev/sda 1 &&  resize2fs /dev/sda1"
# virt-filesystems --long --parts --blkdevs -h -a $file_path

echo "[   NET] - set net.ifnames=0 biosdevname=0"
virt-customize -a $FILE_PATH \
  --edit '/etc/default/grub:s/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 /' \
  --run-command 'update-grub' \
  --run-command 'cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

#auto eth0
#iface eth0 inet static
#     address 192.168.1.100
#     netmask 255.255.255.0
#     gateway 192.168.1.1
#     dns-nameservers 8.8.8.8 8.8.4.4
#     dns-search example.com
#     mtu 1500
#     pre-up /path/to/pre-up-script.sh
#     up /path/to/up-script.sh
#     post-up /path/to/post-up-script.sh
#     pre-down /path/to/pre-down-script.sh
#     down /path/to/down-script.sh
#     post-down /path/to/post-down-script.sh
EOF'


virt-customize -a $FILE_PATH \
  --run-command 'cat << EOF > /opt/scripts/prepere_static_ip.sh
#!/bin/bash
CONFIG_FILE="/etc/network/interfaces"
INTERFACE="eth0"
IP_CIDR=$(ip addr show $INTERFACE | grep -oP 'inet \K[\d.]+/[\d]+')
CURRENT_IP=$(echo $IP_CIDR | cut -d'/' -f1)
CIDR=$(echo $IP_CIDR | cut -d'/' -f2)
cidr_to_netmask() {
    local cidr=$1
    local mask=(0 0 0 0)
    local full_octets=$((cidr / 8))
    local partial_octet=$((cidr % 8))
    for ((i=0; i<full_octets; i++)); do
        mask[i]=255
    done
    if [ $partial_octet -gt 0 ] && [ $full_octets -lt 4 ]; then
        mask[$full_octets]=$((256 - 2**(8-partial_octet)))
    fi
    echo "${mask[0]}.${mask[1]}.${mask[2]}.${mask[3]}"
}
NETMASK=$(cidr_to_netmask $CIDR)
GATEWAY=$(ip route show default | grep -oP 'via \K[\d.]+' | head -1)
sed -i "
s|#.*address.*|#     address $CURRENT_IP|
s|#.*netmask.*|#     netmask $NETMASK|
s|#.*gateway.*|#     gateway $GATEWAY|
" $CONFIG_FILE
EOF' \
  --run-command 'chmod +x /opt/scripts/prepere_static_ip.sh'


echo "[   APT] Add agent to image"
virt-customize -a $FILE_PATH --run-command 'apt-get update && apt-get upgrade -y'


echo "[   APT] Uninstall some libs"
virt-customize -a $FILE_PATH --run-command "rm -R -f /etc/cloud"
virt-customize -a $FILE_PATH --uninstall netplan.io --uninstall cloud-init
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

echo "[   SSH] Set sshd to allow all"
virt-customize -a $FILE_PATH \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.deny; echo 'sshd: ALL' >> /etc/hosts.deny" \
  --run-command "sed -i '/^sshd:/d' /etc/hosts.allow; echo 'sshd: 192.168.0.0/255.255.0.0,10.0.0.0/255.0.0.0,172.16.0.0/255.240.0.0' >> /etc/hosts.allow"


echo "[ GUEST] Install guest agents"
virt-customize -a $FILE_PATH --install qemu-guest-agent,open-vm-tools
# qemu-guest-agent - allow support guest agent
# open-vm-tools - allow support vmware tools



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



echo "[    ..] Add ssh-keygen -A to firstboot"
virt-customize -a $FILE_PATH --firstboot-command 'ssh-keygen -A && systemctl enable ssh && systemctl restart ssh && /opt/scripts/prepere_static_ip.sh'
echo "[    OK] Add ssh-keygen -A to firstboot - done"

# Check if we are on proxmox
if [ -d "/var/lib/vz/import/" ]; then
    echo "[    ..] Copy image to proxmox"
    cp $FILE_PATH /var/lib/vz/import/
    if [ -n "$FINAL_NAME" ]; then
        mv /var/lib/vz/import/$FILE_PATH /var/lib/vz/import/$FINAL_NAME
    fi
    echo "[    OK] Copy image to proxmox - done"
else
    echo "[    OK] No Proxmox detected - skipped copy image to proxmox /var/lib/vz/import/"
fi

echo "[    OK] Cleanup"
rm $FILE_PATH
exit 0