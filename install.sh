#!/bin/bash
# Run INSIDE Ubuntu VM (Proxmox console first, SSH after). Run once.
set -euo pipefail

sudo apt update
sudo apt full-upgrade -y
sudo apt install -y openssh-server qemu-guest-agent python3 python3-psutil curl

sudo systemctl enable --now ssh
sudo systemctl enable --now qemu-guest-agent

# create service user + dirs (assumes agent.py + ubuntukit.service in same folder as this script
# after you scp them over, or copy-paste from Windows)
sudo useradd --system --no-create-home --shell /usr/sbin/nologin ubuntukit || true
sudo mkdir -p /opt/ubuntukit /var/lib/ubuntukit
sudo chown -R ubuntukit:nogroup /var/lib/ubuntukit

# install files - run from dir containing agent.py
sudo cp ./agent.py /opt/ubuntukit/agent.py
sudo chmod 755 /opt/ubuntukit/agent.py
sudo cp ./ubuntukit.service /etc/systemd/system/ubuntukit.service

sudo systemctl daemon-reload
sudo systemctl enable --now ubuntukit
sudo systemctl status ubuntukit --no-pager

echo "OK. Check logs with: sudo journalctl -u ubuntukit -f"
