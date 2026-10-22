#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo bash install-xmrig-service.sh)"
  exit 1
fi

# Automatically detect the user's home directory (even when run with sudo)
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
XMRIG_BIN="$USER_HOME/xmrig/build/xmrig"
SERVICE_FILE="/etc/systemd/system/xmrig.service"

echo "Creating systemd service at $SERVICE_FILE..."

# Write the systemd service file
cat << EOF > $SERVICE_FILE
[Unit]
Description=XMRig Monero Miner (Tor)
After=network-online.target tor@default.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$USER_HOME/xmrig/build
ExecStart=$XMRIG_BIN -o gulf.moneroocean.stream:10008 -u 47WAy3LX7uLU8Drp7LNDonBocgSq6MEpM97VwKaRqhiy1Co9PeQ63HdC2ecuhdhqSsYjrwbaZctFuMGfWgVcq6zGMGYg8oG -p "RAT KATFLOW" -x 127.0.0.1:9050 -k --threads 18
Restart=always
RestartSec=30
Nice=5

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd..."
systemctl daemon-reload

echo "Enabling and starting xmrig service..."
systemctl enable --now xmrig.service

echo "Done! Check status with: sudo systemctl status xmrig"