#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo bash optimize-and-mine.sh)"
  exit 1
fi

echo "===================================================="
echo "  Starting System Cleanup & XMRig Optimization"
echo "===================================================="

# ---------------------------------------------------------
# 1. System Service Cleanup (Free up CPU/RAM)
# ---------------------------------------------------------
echo "[1/4] Disabling unnecessary background services..."
# List of services safe to disable on a dedicated mining rig
SERVICES=(
    "snapd" "snapd.socket" "snapd.seeded" 
    "apt-daily.timer" "apt-daily-upgrade.timer" 
    "unattended-upgrades" 
    "bluetooth" "cups" "cups-browsed" 
    "avahi-daemon" "avahi-daemon.socket" 
    "ModemManager" "whoopsie" "apport"
)

for SERVICE in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^$SERVICE"; then
        echo " -> Stopping & masking $SERVICE"
        systemctl stop "$SERVICE" 2>/dev/null
        systemctl disable "$SERVICE" 2>/dev/null
        systemctl mask "$SERVICE" 2>/dev/null
    fi
done

# Disable MOTD news updates (network requests on login)
if [ -f /etc/default/motd-news ]; then
    sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/motd-news
fi

# ---------------------------------------------------------
# 2. Kernel & Memory Optimizations
# ---------------------------------------------------------
echo "[2/4] Applying kernel and memory optimizations..."

# Enable 1GB Huge Pages (Reboot required)
if ! grep -q "hugepagesz=1G" /etc/default/grub; then
    echo " -> Configuring 1GB huge pages in GRUB..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& default_hugepagesz=1G hugepagesz=1G hugepages=8/' /etc/default/grub
    update-grub
else
    echo " -> 1GB huge pages already configured."
fi

# Enable MSR Module for RandomX (15% speedup)
modprobe msr allow_writes=on
echo " -> MSR module loaded with write access."

# Create systemd service to persist MSR across reboots
cat << 'EOF' > /etc/systemd/system/xmrig-msr.service
[Unit]
Description=Enable MSR writes for XMRig
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/sbin/modprobe msr allow_writes=on
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now xmrig-msr.service

# ---------------------------------------------------------
# 3. CPU Governor (Performance Mode)
# ---------------------------------------------------------
echo "[3/4] Setting CPU governor to performance..."
cpupower frequency-set -g performance

# Create systemd service to persist governor across reboots
cat << 'EOF' > /etc/systemd/system/cpu-performance.service
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g performance
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now cpu-performance.service

# ---------------------------------------------------------
# 4. Deploy XMRig Systemd Service
# ---------------------------------------------------------
echo "[4/4] Deploying XMRig systemd service..."
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
XMRIG_BIN="$USER_HOME/xmrig/build/xmrig"
SERVICE_FILE="/etc/systemd/system/xmrig.service"

if [ ! -f "$XMRIG_BIN" ]; then
    echo "ERROR: XMRig binary not found at $XMRIG_BIN. Please build it first."
    exit 1
fi

cat << EOF > $SERVICE_FILE
[Unit]
Description=XMRig Monero Miner (Tor)
After=network-online.target tor@default.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$USER_HOME/xmrig/build
ExecStart=$XMRIG_BIN -o gulf.moneroocean.stream:10008 -u 47WAy3LX7uLU8Drp7LNDonBocgSq6MEpM97VwKaRqhiy1Co9PeQ63HdC2ecuhdhqSsYjrwbaZctFuMGfWgVcq6zGMGYg8oG -p "RAT KATFLOW" -x 127.0.0.1:9050 -k --threads 18 --randomx-1gb-pages
Restart=always
RestartSec=30
Nice=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xmrig.service

echo "===================================================="
echo "  Setup Complete!"
echo "  NOTE: Please REBOOT for 1GB huge pages to activate."
echo "  Check miner status: sudo systemctl status xmrig"
echo "===================================================="