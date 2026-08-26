#!/usr/bin/env bash
# dut_restore.sh -- undo the invasive CPU changes from dut_prepare.sh and detach
# XDP, returning the DuT to a normal interactive state. The persistent boot-time
# isolation (isolcpus etc.) is unaffected. NIC single-queue is left in place (it
# is the measurement default and harmless); pass "nic" as $2 to also restore
# multi-queue.
#
#   ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1' < scripts/dut_restore.sh
#
# Args: $1 = interface (default enp35s0f1)   $2 = "nic" to also reset queues
set -uo pipefail
IFACE="${1:-enp35s0f1}"

echo "== detach XDP and clear leftover raw-table DROP rules =="
ip link set dev "$IFACE" xdp off 2>/dev/null || true
while iptables-legacy -t raw -D PREROUTING -j DROP 2>/dev/null; do :; done
while iptables-legacy -t raw -D PREROUTING -i "$IFACE" -j DROP 2>/dev/null; do :; done
while iptables-nft -t raw -D PREROUTING -j DROP 2>/dev/null; do :; done

echo "== SMT on, governor schedutil, boost on =="
[ -w /sys/devices/system/cpu/smt/control ] && echo on > /sys/devices/system/cpu/smt/control
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] && echo schedutil > "$g" 2>/dev/null || true
done
[ -w /sys/devices/system/cpu/cpufreq/boost ] && echo 1 > /sys/devices/system/cpu/cpufreq/boost || true
# re-enable all cpuidle states on cpu10/11
for s in /sys/devices/system/cpu/cpu1[01]/cpuidle/state*/disable; do
  [ -w "$s" ] && echo 0 > "$s" 2>/dev/null || true
done

if [ "${2:-}" = nic ]; then
  echo "== restore multi-queue (combined 12) =="
  ethtool -L "$IFACE" combined 12 2>/dev/null || true
fi
echo "== restored (isolcpus boot params unchanged) =="
