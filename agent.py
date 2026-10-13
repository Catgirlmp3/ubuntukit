#!/usr/bin/env python3
"""ubuntukit - local-only maintenance agent for own Ubuntu VM on Proxmox.

Does NOT listen on network, does NOT execute remote commands.
- collects CPU/mem/disk every INTERVAL seconds
- appends to /var/log/ubuntukit/health.log (via journal stdout)
- saves state to /var/lib/ubuntukit/state.json
- fully manageable via systemd (enable/disable/stop/uninstall)

Remote admin is done via OpenSSH + Tailscale, not here.
"""
import json
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path

STATE_FILE = Path("/var/lib/ubuntukit/state.json")
INTERVAL = 60

try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False


def collect():
    if HAS_PSUTIL:
        return {
            "cpu_percent": psutil.cpu_percent(interval=1),
            "mem_percent": psutil.virtual_memory().percent,
            "disk_percent": psutil.disk_usage("/").percent,
        }
    # fallback without psutil: read /proc/loadavg + df
    try:
        load = open("/proc/loadavg").read().split()[:3]
    except Exception:
        load = []
    try:
        total, used, free = shutil.disk_usage("/")
        disk_pct = round(used / total * 100, 1)
    except Exception:
        disk_pct = -1
    return {"loadavg": load, "disk_percent": disk_pct}


def main():
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    print("ubuntukit starting, interval=%ss psutil=%s" % (INTERVAL, HAS_PSUTIL), flush=True)
    while True:
        sample = collect()
        sample["ts"] = datetime.now(timezone.utc).isoformat()
        # stdout -> journald (journalctl -u ubuntukit)
        print(json.dumps(sample), flush=True)
        try:
            STATE_FILE.write_text(json.dumps(sample, indent=2))
        except Exception as e:
            print("state write failed: %s" % e, flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
