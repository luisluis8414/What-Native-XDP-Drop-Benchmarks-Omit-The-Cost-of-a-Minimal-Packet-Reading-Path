#!/usr/bin/env bash
# trex_start.sh -- start the TRex server on the tester in interactive/stateless
# mode. Binds both X520 ports to vfio-pci (they disappear from the kernel until
# trex_stop.sh). Runs the server detached, waits for the STL RPC port, prints the
# log path. Run on the tester (generator).
#
#   scripts/trex_start.sh
#
# Env overrides: TREX_DIR (default /opt/trex/v3.08), CFG (default repo cfg).
set -euo pipefail
TREX_DIR="${TREX_DIR:-/opt/trex/v3.08}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${CFG:-$REPO/scripts/trex/trex_cfg.yaml}"
LOG="${LOG:-/tmp/trex_server.log}"

[ -f "$CFG" ] || { echo "missing cfg: $CFG" >&2; exit 1; }

# Prerequisites: hugepages + vfio.
hp=$(awk '/HugePages_Free/{print $2}' /proc/meminfo)
[ "${hp:-0}" -ge 128 ] || echo "WARNING: only $hp free hugepages" >&2
sudo modprobe vfio-pci

echo "starting TRex ($TREX_DIR) with $CFG -> $LOG"
( cd "$TREX_DIR" && sudo setsid ./t-rex-64 -i --cfg "$CFG" >"$LOG" 2>&1 </dev/null & )

# wait for the STL RPC port (4501) or a fatal log line
for i in $(seq 1 45); do
  if ss -ltnH 2>/dev/null | grep -q ':4501'; then
    echo "TRex ready (RPC 4501 listening). log: $LOG"
    grep -m1 -iE 'link *: *Link Up' "$LOG" || true
    exit 0
  fi
  if grep -qiE 'fatal|cannot bind|no such device|shutting down' "$LOG" 2>/dev/null; then
    echo "TRex failed to start:" >&2; tail -15 "$LOG" >&2; exit 1
  fi
  sleep 1
done
echo "TRex did not become ready in 45s" >&2; tail -20 "$LOG" >&2; exit 2
