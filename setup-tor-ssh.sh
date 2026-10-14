#!/bin/bash
# setup-tor-ssh.sh - one-command remote-admin setup for YOUR OWN machines.
# Paste-and-run, no editing. Works piped straight into bash:
#
#   curl -fsSL https://raw.githubusercontent.com/Catgirlmp3/ubuntukit/main/setup-tor-ssh.sh | sudo bash
#
# Keys auto-fetch from https://github.com/Catgirlmp3.keys (zero-edit).
# Optional override (piped runs need `bash -s --` for args):
#   curl -fsSL .../setup-tor-ssh.sh | sudo bash -s -- 'ssh-ed25519 AAA...'
#
# Two modes, auto-detected:
#   Proxmox host (/etc/pve present): keys-only for root. No SSH policy
#     changes, no agent, no Tor here - workers and hosts unaffected.
#     The gateway maps this box afterwards.
#   Ubuntu VM: own Tor onion for SSH + key-only hardening + ubuntukit agent.
#     Missing agent.py/ubuntukit.service are auto-fetched from the repo.
set -euo pipefail

GITHUB_USER="Catgirlmp3"
REPO_RAW="https://raw.githubusercontent.com/Catgirlmp3/ubuntukit/main"
PUBKEY_ARG="${1:-}"
TARGET_USER="${SUDO_USER:-${USER:-root}}"
[ -z "$TARGET_USER" ] && TARGET_USER="root"

IS_PROXMOX=0
if [ -e /etc/pve/.version ] || command -v pveversion >/dev/null 2>&1; then
  IS_PROXMOX=1
fi

install_keys_for() { # install_keys_for <user> <keys_file>
  local u="$1" kf="$2" home
  home=$(eval echo "~$u")
  if [ ! -d "$home" ]; then
    echo "WARN: no home directory for user $u, skipping key install."
    return 1
  fi
  mkdir -p "$home/.ssh"
  chmod 700 "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  local k added=0
  while IFS= read -r k || [ -n "$k" ]; do
    [ -z "$k" ] && continue
    case "$k" in \#*) continue;; esac
    if ! grep -qF "$k" "$home/.ssh/authorized_keys"; then
      echo "$k" >> "$home/.ssh/authorized_keys"
      added=$((added+1))
    fi
  done < "$kf"
  if id "$u" >/dev/null 2>&1; then
    chown -R "$u:$u" "$home/.ssh" 2>/dev/null || chown -R "$u" "$home/.ssh"
  fi
  echo "Installed $added new key(s) for $u."
}

echo "Fetching SSH keys..."
KEYS_TMP="$(mktemp)"
if [ -n "$PUBKEY_ARG" ]; then
  echo "$PUBKEY_ARG" > "$KEYS_TMP"
else
  if curl -fsSL "https://github.com/$GITHUB_USER.keys" -o "$KEYS_TMP" 2>/dev/null && [ -s "$KEYS_TMP" ]; then
    echo "Fetched keys for $GITHUB_USER."
  else
    echo "WARN: could not fetch https://github.com/$GITHUB_USER.keys."
    : > "$KEYS_TMP"
  fi
fi

if [ "$IS_PROXMOX" = "1" ]; then
  echo "[proxmox] Keys-only mode: touching nothing else (workers unaffected)."
  apt update
  apt install -y openssh-server curl
  systemctl enable --now ssh 2>/dev/null || service ssh start 2>/dev/null || true
  if [ -s "$KEYS_TMP" ]; then
    install_keys_for root "$KEYS_TMP" || true
    sshd -t && echo "sshd config OK (unchanged)."
  else
    echo "No keys available - SSH left exactly as it was."
    echo "Add a key to https://github.com/$GITHUB_USER.keys and re-run."
  fi
  rm -f "$KEYS_TMP"
  echo ""
  echo "===== DONE (proxmox target) ====="
  echo "Next: on gateway .1 run: sudo bash setup-tor-gateway.sh"
  echo "It will pick this box up as the next free port."
  exit 0
fi

echo "[1/5] Installing packages..."
apt update
apt install -y openssh-server tor qemu-guest-agent python3 python3-psutil curl
systemctl enable --now ssh
systemctl enable --now qemu-guest-agent

echo "[2/5] Configuring Tor hidden service for SSH (port 22)..."
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
systemctl enable --now tor
systemctl restart tor
sleep 5

echo "[3/5] Installing SSH keys..."
if [ -s "$KEYS_TMP" ]; then
  install_keys_for "$TARGET_USER" "$KEYS_TMP"
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
  echo "No keys found - leaving password login ON so you don't lock yourself out."
  echo "Add a key to https://github.com/$GITHUB_USER.keys then re-run."
fi
rm -f "$KEYS_TMP"

echo "[5/5] Installing ubuntukit persistent service (local-only, no network)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
AGENT_SRC="$SCRIPT_DIR/agent.py"
SERVICE_SRC="$SCRIPT_DIR/ubuntukit.service"
if [ ! -f "$AGENT_SRC" ] || [ ! -f "$SERVICE_SRC" ]; then
  echo " Companion files not beside script (piped run?) - fetching from repo..."
  FETCH_DIR="$(mktemp -d)"
  if curl -fsSL "$REPO_RAW/agent.py" -o "$FETCH_DIR/agent.py" \
  && curl -fsSL "$REPO_RAW/ubuntukit.service" -o "$FETCH_DIR/ubuntukit.service"; then
    AGENT_SRC="$FETCH_DIR/agent.py"
    SERVICE_SRC="$FETCH_DIR/ubuntukit.service"
  else
    echo "Fetch failed - skipping ubuntukit (SSH+Tor still configured)."
    AGENT_SRC=""
    SERVICE_SRC=""
  fi
fi
if [ -n "$AGENT_SRC" ] && [ -f "$AGENT_SRC" ] && [ -f "$SERVICE_SRC" ]; then
  id -u ubuntukit >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin ubuntukit
  mkdir -p /opt/ubuntukit /var/lib/ubuntukit
  cp "$AGENT_SRC" /opt/ubuntukit/agent.py
  # hygiene vs non-root users only: root can still read/stop anything (see RUN.txt)
  chown -R root:ubuntukit /opt/ubuntukit
  chmod 750 /opt/ubuntukit
  chmod 750 /opt/ubuntukit/agent.py
  cp "$SERVICE_SRC" /etc/systemd/system/ubuntukit.service
  chown -R ubuntukit:nogroup /var/lib/ubuntukit
  chmod 700 /var/lib/ubuntukit
  systemctl daemon-reload
  systemctl enable --now ubuntukit
else
  echo "agent.py / ubuntukit.service unavailable, skipping (SSH+Tor still configured)."
fi

echo ""
echo "===== DONE ====="
echo "Onion address (KEEP PRIVATE - it is your access):"
cat /var/lib/tor/ssh_hidden_service/hostname || echo "not ready yet, retry: sudo cat /var/lib/tor/ssh_hidden_service/hostname"
echo ""
echo "Test on VM: systemctl is-active tor ssh ubuntukit"
echo "Proxmox web -> VM Options -> Start at boot = Yes"
