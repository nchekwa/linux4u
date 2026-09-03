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
# /run/selkies, owned by ${DESKTOP_USER}: start-desktop.sh publishes the session
# D-Bus address here for selkies.service to pick up. Preserve=yes so a desktop
# restart does not delete the file under a still-running selkies.service.
RuntimeDirectory=selkies
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes

[Install]
WantedBy=multi-user.target
