#!/bin/bash
# setup-tor-gateway.sh - paste-and-run on your Proxmox host / gateway. No editing.
# Same command on every setup; it auto-detects live machines and picks next free onion ports.
#
#   curl -fsSL https://raw.githubusercontent.com/Catgirlmp3/ubuntukit/main/setup-tor-gateway.sh -o setup-tor-gateway.sh
#   sudo bash setup-tor-gateway.sh
#
# Optional overrides (no edit needed, only if defaults are wrong):
#   sudo SUBNET=17.216.3 MAX_HOST=20 WEB_SRC=8006 SSH_BASE=2221 bash setup-tor-gateway.sh
#
# What it does (idempotent, safe to re-run after adding .5, .6...):
#   1. finds subnet from default route (fallback 17.216.3.x)
#   2. scans SUBNET.1..MAX_HOST for open 22 (ssh) and 8006 (proxmox web)
#   3. reads existing /etc/tor/torrc HiddenServicePort lines (which vports are used)
#   4. keeps existing mappings, appends only missing hosts with next free vport (2221, 2222...)
#   5. restarts tor, prints onion + mapping table
set -euo pipefail

SUBNET="${SUBNET:-auto}"
MAX_HOST="${MAX_HOST:-20}"
WEB_SRC="${WEB_SRC:-8006}"
SSH_BASE="${SSH_BASE:-2221}"
TORRC="/etc/tor/torrc"
HSDIR="/var/lib/tor/proxmox_gateway"

echo "[0/4] Installing tor/curl/iproute2..."
apt update
apt install -y tor curl iproute2
systemctl enable --now tor

# --- detect subnet ---
if [ "$SUBNET" = "auto" ]; then
  DEV=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1 || true)
  CIDR=$(ip -4 -o addr show dev "$DEV" 2>/dev/null | awk '{print $4}' | head -n1 || true)
  # CIDR like 17.216.3.12/24 -> prefix 17.216.3
  SUBNET=$(echo "$CIDR" | cut -d/ -f1 | cut -d. -f1-3 || true)
  if [ -z "$SUBNET" ] || [ "$SUBNET" = "" ]; then SUBNET="17.216.3"; fi
fi
echo "Subnet: $SUBNET.1-$MAX_HOST"

is_open() { # is_open <ip> <port>
  timeout 1 bash -c "cat < /dev/null > /dev/tcp/$1/$2" 2>/dev/null
}

echo "[1/4] Scanning for live SSH/web hosts (this takes a few seconds)..."
LIVE_SSH=""
LIVE_WEB=""
for i in $(seq 1 "$MAX_HOST"); do
  ip="$SUBNET.$i"
  if is_open "$ip" 22; then LIVE_SSH="$LIVE_SSH $ip"; fi
  if is_open "$ip" 8006; then LIVE_WEB="$LIVE_WEB $ip"; fi
  echo -n "."
done
echo ""
echo "Live SSH:$LIVE_SSH"
echo "Live web:$LIVE_WEB"

# --- ensure base torrc block ---
cp -a "$TORRC" "$TORRC.bak.$(date +%s)" 2>/dev/null || true
touch "$TORRC"
if ! grep -q "HiddenServiceDir $HSDIR/" "$TORRC" 2>/dev/null; then
  cat >> "$TORRC" <<EOF

# ubuntukit gateway (auto-managed by setup-tor-gateway.sh, safe to re-run)
HiddenServiceDir $HSDIR/
SocksPort 127.0.0.1:9050
EOF
fi
if ! grep -q "^SocksPort" "$TORRC"; then
  echo "SocksPort 127.0.0.1:9050" >> "$TORRC"
fi

used_vports() { grep -E "^HiddenServicePort +[0-9]+" "$TORRC" 2>/dev/null | awk '{print $2}' || true; }
is_mapped() { # is_mapped <ip:port>
  grep -qE "^HiddenServicePort +[0-9]+ +$1$" "$TORRC" 2>/dev/null
}
next_free() { # next_free <base>
  local p=$1
  local used
  used=$(used_vports)
  while echo "$used" | grep -qx "$p" 2>/dev/null; do p=$((p+1)); done
  echo "$p"
}

echo "[2/4] Mapping Proxmox web (keep existing :$WEB_SRC)..."
if [ -n "$LIVE_WEB" ]; then
  # keep first existing web mapping if present, else map first live web host
  if ! grep -qE "^HiddenServicePort +$WEB_SRC +" "$TORRC"; then
    first_web=$(echo "$LIVE_WEB" | awk '{print $1}')
    echo "HiddenServicePort $WEB_SRC $first_web:8006" >> "$TORRC"
    echo "  + $WEB_SRC -> $first_web:8006"
  else
    echo "  = web mapping already present, keeping it"
  fi
  # extra web hosts get 8007, 8008... only if not already mapped
  extra_port=$((WEB_SRC+1))
  for ip in $LIVE_WEB; do
    if ! is_mapped "$ip:8006"; then
      # skip if this ip is the one already mapped to WEB_SRC
      if grep -qE "^HiddenServicePort +$WEB_SRC +$ip:8006$" "$TORRC"; then continue; fi
      p=$(next_free "$extra_port")
      echo "HiddenServicePort $p $ip:8006" >> "$TORRC"
      echo "  + $p -> $ip:8006"
      extra_port=$((p+1))
    fi
  done
fi

echo "[3/4] Mapping SSH (next free from $SSH_BASE)..."
for ip in $LIVE_SSH; do
  if is_mapped "$ip:22"; then
    echo "  = $ip:22 already mapped, skipping"
    continue
  fi
  p=$(next_free "$SSH_BASE")
  echo "HiddenServicePort $p $ip:22" >> "$TORRC"
  echo "  + $p -> $ip:22"
  SSH_BASE=$((p+1))
done

echo "[4/4] Restarting tor..."
systemctl restart tor
sleep 6
systemctl is-active tor

echo ""
echo "===== DONE ====="
echo "Onion (KEEP PRIVATE):"
cat "$HSDIR/hostname" 2>/dev/null || echo "not ready yet, retry: sudo cat $HSDIR/hostname"
echo ""
echo "Active mappings:"
grep -E "^HiddenServicePort" "$TORRC" || true
echo ""
echo "PuTTY: SOCKS5 127.0.0.1:9150 (Tor Browser open), Host=<onion>, Port=<vport above>"
echo "Re-run this same script after adding a new machine (.5, .6...) - it only adds the new one."
