#!/usr/bin/env bash
# trex_stop.sh -- stop the TRex server and rebind the X520 ports to the ixgbe
# kernel driver. Killing TRex (rather than console `quit`) leaves the ports on
# vfio-pci, so we rebind deterministically and verify the DAC link returns.
# Run on the tester.
#
#   scripts/trex_stop.sh
set -uo pipefail
TREX_DIR="${TREX_DIR:-/opt/trex/v3.08}"
PORTS=("01:00.0" "01:00.1")

echo "== stopping TRex =="
sudo pkill -TERM -f '[t]-rex-64' 2>/dev/null || true
for i in 1 2 3 4 5; do pgrep -f '[t]-rex-64' >/dev/null || break; sleep 1; done
pgrep -f '[t]-rex-64' >/dev/null && { echo "  SIGKILL"; sudo pkill -KILL -f '[t]-rex-64'; sleep 2; }

echo "== rebinding ${PORTS[*]} -> ixgbe =="
sudo python3 "$TREX_DIR/dpdk_nic_bind.py" --force --bind=ixgbe "${PORTS[@]}" 2>/dev/null || true
sleep 2

# A killed TRex (vs. console `quit`) leaves rtemap_* files in the hugepage mount,
# so HugePages_Free stays 0 even though nothing holds them. Free them once TRex
# is gone, so the next start has the full reservation.
if ! pgrep -f '[t]-rex-64' >/dev/null; then
  sudo rm -f /dev/hugepages/rtemap_* 2>/dev/null || true
fi
echo "== hugepages free: $(awk '/HugePages_Free/{print $2}' /proc/meminfo) =="

echo "== status =="
for bdf in "${PORTS[@]}"; do
  drv=$(basename "$(readlink -f /sys/bus/pci/devices/0000:$bdf/driver 2>/dev/null)" 2>/dev/null)
  printf '  %s -> %s\n' "$bdf" "${drv:-UNBOUND}"
done
ip -br link show enp1s0f1 2>/dev/null || true
