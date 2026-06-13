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
