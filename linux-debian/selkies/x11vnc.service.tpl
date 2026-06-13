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
