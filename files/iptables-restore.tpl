[Unit]
Description=Restore iptables
# iptables-restore must start after docker because docker will
# reconfigure iptables to drop forwarded packets.
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c "/sbin/iptables-restore -c ${IPTABLES_RULES}"

[Install]
WantedBy=multi-user.target
