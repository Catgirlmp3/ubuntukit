#!/bin/bash
# setup-tor-ssh.sh - one-command remote-admin setup for YOUR OWN Ubuntu VM on Proxmox.
# Uses only standard tools: OpenSSH + Tor onion service. No custom RCE daemon.
#
# Upload this + agent.py + ubuntukit.service to a public GitHub repo,
# then on the VM (Proxmox console) - same command on EVERY machine, no editing:
#   curl -fsSL https://raw.githubusercontent.com/Catgirlmp3/ubuntukit/main/setup-tor-ssh.sh -o setup-tor-ssh.sh
#   sudo bash setup-tor-ssh.sh
#
# Keys auto-fetch from https://github.com/Catgirlmp3.keys (zero-edit).
# Optional override: sudo bash setup-tor-ssh.sh 'ssh-ed25519 AAA...'
#
# If no key is found, password login stays enabled so you don't lock yourself out.
set -euo pipefail

GITHUB_USER="Catgirlmp3"
PUBKEY_ARG="${1:-}"
TARGET_USER="${SUDO_USER:-$USER}"
if [ "$TARGET_USER" = "root" ]; then TARGET_USER="ubuntu"; fi

echo "[1/5] Installing packages..."
apt update
apt install -y openssh-server tor qemu-guest-agent python3 python3-psutil curl
systemctl enable --now ssh
systemctl enable --now qemu-guest-agent

echo "[2/5] Configuring Tor hidden service for SSH (port 22)..."
# Idempotent: only append if not present
if ! grep -q "HiddenServiceDir /var/lib/tor/ssh_hidden_service/" /etc/tor/torrc 2>/dev/null; then
cat >> /etc/tor/torrc <<'EOF'

# ubuntukit: expose local SSH as onion service
HiddenServiceDir /var/lib/tor/ssh_hidden_service/
HiddenServicePort 22 127.0.0.1:22
# Tor SOCKS for local use (PuTTY / ssh ProxyCommand point here)
SocksPort 127.0.0.1:9050
EOF
fi

# If your ISP censors Tor, add your bridge lines to /etc/tor/torrc BEFORE restart, e.g:
#   UseBridges 1
#   Bridge obfs4 <IP:PORT> <FINGERPRINT> cert=... iat-mode=...
# You said Tor Browser already works, so usually no bridge needed on the server side.

systemctl enable --now tor
systemctl restart tor
sleep 5

echo "[3/5] Installing SSH keys (auto-fetch from GitHub, no edit)..."
KEYS_TMP="$(mktemp)"
if [ -n "$PUBKEY_ARG" ]; then
  echo "$PUBKEY_ARG" > "$KEYS_TMP"
else
  if curl -fsSL "https://github.com/$GITHUB_USER.keys" -o "$KEYS_TMP" 2>/dev/null && [ -s "$KEYS_TMP" ]; then
    echo "Fetched keys for $GITHUB_USER."
  else
    echo "WARN: could not fetch https://github.com/$GITHUB_USER.keys, leaving passwords on."
    : > "$KEYS_TMP"
  fi
fi
if [ -s "$KEYS_TMP" ]; then
  UHOME=$(eval echo "~$TARGET_USER")
  mkdir -p "$UHOME/.ssh"
  chmod 700 "$UHOME/.ssh"
  touch "$UHOME/.ssh/authorized_keys"
  chmod 600 "$UHOME/.ssh/authorized_keys"
  chown -R "$TARGET_USER:$TARGET_USER" "$UHOME/.ssh"
  while IFS= read -r k || [ -n "$k" ]; do
    [ -z "$k" ] && continue
    if ! grep -qF "$k" "$UHOME/.ssh/authorized_keys"; then
      echo "$k" >> "$UHOME/.ssh/authorized_keys"
    fi
  done < "$KEYS_TMP"
  echo "Keys installed for $TARGET_USER."
  echo "[4/5] Hardening SSH (key-only, safe because keys are installed)..."
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-local-hardening.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
ChallengeResponseAuthentication no
EOF
  sshd -t && systemctl reload ssh
else
  echo "No pubkey found - leaving password login ON so you don't lock yourself out."
  echo "Add a key to https://github.com/$GITHUB_USER.keys then re-run: sudo bash setup-tor-ssh.sh"
fi
rm -f "$KEYS_TMP"

echo "[4/5] Installing ubuntukit persistent service (local-only, no network)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/agent.py" ] && [ -f "$SCRIPT_DIR/ubuntukit.service" ]; then
  id -u ubuntukit >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin ubuntukit
  mkdir -p /opt/ubuntukit /var/lib/ubuntukit
  cp "$SCRIPT_DIR/agent.py" /opt/ubuntukit/agent.py
  chmod 755 /opt/ubuntukit/agent.py
  cp "$SCRIPT_DIR/ubuntukit.service" /etc/systemd/system/ubuntukit.service
  chown -R ubuntukit:nogroup /var/lib/ubuntukit
  systemctl daemon-reload
  systemctl enable --now ubuntukit
else
  echo "agent.py / ubuntukit.service not in same dir, skipping (SSH+Tor still configured)."
fi

echo ""
echo "===== DONE ====="
echo "Onion address (KEEP PRIVATE - it is your access):"
cat /var/lib/tor/ssh_hidden_service/hostname || echo "not ready yet, retry: sudo cat /var/lib/tor/ssh_hidden_service/hostname"
echo ""
echo "Test on VM: systemctl is-active tor ssh ubuntukit"
echo "Proxmox web -> VM Options -> Start at boot = Yes"
