#!/bin/sh
# Live login banner for the Selkies desktop appliance.
# Run by pam_motd via /etc/update-motd.d/ on each login -> the IP is resolved
# fresh every time. ${DESKTOP_USER} / ${SELKIES_USER} are filled at build time
# (envsubst, restricted var list); ${IP} stays literal and is computed here.
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || IP="<vm-ip>"
cat <<EOF

=============== Selkies desktop appliance ===============

 Selkies (web)    https://${IP}:8080
   login          ${SELKIES_USER}      (default password - change it)
   change pass     edit /opt/selkies/start-selkies.sh  (--basic_auth_password=)
                   sudo systemctl restart selkies.service

 VNC (localhost)  ssh -L 5900:127.0.0.1:5900 ${DESKTOP_USER}@${IP}
                   then point a VNC viewer at 127.0.0.1:5900  (password only)
   change pass     x11vnc -storepasswd <newpass> ~/.vnc/passwd
                   sudo systemctl restart x11vnc.service

 Desktop          sudo systemctl restart xfce-session.service   (restarts all)

=========================================================
EOF
