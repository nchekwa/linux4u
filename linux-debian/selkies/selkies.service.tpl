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
# Scheduling: PulseAudio inside the stream logs "Failed to acquire high-priority
# / real-time scheduling: Input/output error" at the default limits. Granting
# them reduces encode jitter and audio glitching when the host is busy.
Nice=-5
LimitRTPRIO=infinity
LimitNICE=-15
IOSchedulingClass=best-effort
IOSchedulingPriority=2

[Install]
WantedBy=multi-user.target
