#!/usr/bin/env bash
# dut_prepare.sh -- bring the DuT into the clean single-core XDP measurement
# state: NIC normalization (single queue, no flow control, fixed rings/coalescing,
# offloads off) + CPU/IRQ isolation (performance governor, boost off, SMT off,
# deep C-states off on the measurement core, queue IRQ pinned).
#
# Run ON the DuT as root, or pipe from the tester:
#   ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1 10 512' < scripts/dut_prepare.sh
#
# Persistent isolation (isolcpus/nohz_full/rcu_nocbs/irqaffinity) is set via the
# GRUB cmdline and is NOT touched here; verify it with dut_audit.sh.
#
# Args: $1 = interface   $2 = measurement CPU   $3 = required RX ring size
set -uo pipefail

usage() {
  echo "usage: $0 <interface> <measurement-cpu> <rx-ring-size>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
IFACE=$1
CPU=$2
RX_RING=$3
[[ "$CPU" =~ ^[0-9]+$ ]] || { echo "invalid measurement CPU: $CPU" >&2; exit 2; }
[[ "$RX_RING" =~ ^[1-9][0-9]*$ ]] \
  || { echo "invalid RX ring size: $RX_RING" >&2; exit 2; }

log() { printf '  %-42s %s\n' "$1" "${2:-}"; }
sw()  { echo "== $* =="; }

sw "NIC normalization: $IFACE"
# Stop orphaned benches before detaching. Detaching alone would leave them
# polling on the measurement core, and dut_audit.sh then reports them.
if systemctl list-units --all --no-legend 'xdpbench-cell-*' 2>/dev/null | grep -q .; then
  systemctl stop 'xdpbench-cell-*' 2>/dev/null || true
  systemctl reset-failed 'xdpbench-cell-*' 2>/dev/null || true
  log "orphaned xdp-bench units" "stopped"
fi
ip link set dev "$IFACE" xdp off 2>/dev/null || true
ip link set dev "$IFACE" up
ethtool -L "$IFACE" combined 1        2>/dev/null && log "combined queues" "1"      || log "combined queues" "(unchanged)"
ethtool -A "$IFACE" rx off tx off     2>/dev/null && log "flow control"    "off"    || log "flow control" "(n/a)"
if ! ethtool -G "$IFACE" rx "$RX_RING" tx 4096 2>/dev/null; then
  echo "  !! ERROR: could not set RX ring to $RX_RING on $IFACE" >&2
  exit 1
fi
ACTUAL_RX=$(ethtool -g "$IFACE" 2>/dev/null \
  | awk '/^Current hardware settings:/{f=1;next} f&&/^RX:/{print $2;exit}')
ACTUAL_TX=$(ethtool -g "$IFACE" 2>/dev/null \
  | awk '/^Current hardware settings:/{f=1;next} f&&/^TX:/{print $2;exit}')
if [ "$ACTUAL_RX" != "$RX_RING" ] || [ "$ACTUAL_TX" != 4096 ]; then
  echo "  !! ERROR: ring setting not applied: got rx=${ACTUAL_RX:-unknown}/tx=${ACTUAL_TX:-unknown}, want rx=$RX_RING/tx=4096" >&2
  exit 1
fi
log "rings rx/tx" "$ACTUAL_RX/$ACTUAL_TX"
ethtool -C "$IFACE" rx-usecs 1 tx-usecs 0 2>/dev/null && log "coalescing"  "rx1/tx0" || log "coalescing" "(n/a)"
for f in gro gso tso lro sg rx tx rxvlan txvlan; do
  ethtool -K "$IFACE" "$f" off >/dev/null 2>&1 || true
done
log "offloads gro/gso/tso/lro/sg/vlan" "off (where supported)"
# RPS/RFS off (no software receive steering)
# The interface only ever receives generated test traffic, so silence the stack
# chatter it would otherwise emit (neighbour discovery, multicast listener
# reports). Those packets are harmless but they show up in the transmit counter
# that guards against packets escaping the drop path.
sysctl -qw net.ipv6.conf."$IFACE".disable_ipv6=1 2>/dev/null || true
log "IPv6 on $IFACE" "disabled"
for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus;      do [ -e "$q" ] && echo 0 > "$q" 2>/dev/null || true; done
for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_flow_cnt;  do [ -e "$q" ] && echo 0 > "$q" 2>/dev/null || true; done
sysctl -qw net.core.rps_sock_flow_entries=0 2>/dev/null || true
log "RPS/RFS" "off"
sysctl -qw kernel.bpf_stats_enabled=0 2>/dev/null || true
log "bpf_stats_enabled" "0"

# Connection tracking is a different and far more expensive baseline than the
# raw-table drop under test. It must not be attached to the measured path, so
# unload it if some earlier command pulled it in. A busy module cannot be
# removed, which dut_audit.sh then reports as a FAIL.
if lsmod | grep -q '^nf_conntrack'; then
  modprobe -r nf_conntrack 2>/dev/null || true
fi
lsmod | grep -q '^nf_conntrack' && log "nf_conntrack" "STILL LOADED (see audit)" || log "nf_conntrack" "not loaded"

# ethtool -L flaps the ixgbe link; wait for it to come back.
printf '  %-42s ' "waiting for link"
for i in $(seq 1 15); do
  [ "$(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null)" = up ] && { echo "up"; break; }
  sleep 1
done

sw "CPU / IRQ isolation: measurement CPU $CPU"
# governor + boost (before SMT off, while all siblings are online)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] && echo performance > "$g" 2>/dev/null || true
done
log "governor" "performance"
[ -w /sys/devices/system/cpu/cpufreq/boost ] && echo 0 > /sys/devices/system/cpu/cpufreq/boost
log "boost" "off"
# irqbalance out of the way (if present)
systemctl stop irqbalance 2>/dev/null || true
systemctl disable irqbalance 2>/dev/null || true
log "irqbalance" "stopped/disabled (if present)"
# deep C-states off on the measurement core (keep POLL + C1)
for s in /sys/devices/system/cpu/cpu"$CPU"/cpuidle/state*/; do
  idx=$(basename "$s" | tr -dc 0-9)
  [ "${idx:-0}" -ge 2 ] && echo 1 > "$s/disable" 2>/dev/null || true
done
log "deep C-states on cpu$CPU" "disabled (>= C2)"
# SMT off -> the sibling of the measurement core goes offline
[ -w /sys/devices/system/cpu/smt/control ] && echo off > /sys/devices/system/cpu/smt/control
log "SMT" "off"
if ! grep -qw "$CPU" <(tr ',' ' ' < /sys/devices/system/cpu/online); then
  echo "  !! WARNING: cpu$CPU is OFFLINE after SMT off -- check the sibling map" >&2
fi
# pin the single queue IRQ to the measurement core (re-derive, never hardcode)
IRQ=$(grep -i "${IFACE}-TxRx-0" /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1;exit}')
if [ -n "${IRQ:-}" ]; then
  echo "$CPU" > /proc/irq/"$IRQ"/smp_affinity_list 2>/dev/null \
    && log "queue IRQ $IRQ -> cpu$CPU" "pinned" || log "queue IRQ $IRQ" "(pin failed)"
else
  echo "  !! WARNING: could not find ${IFACE}-TxRx-0 IRQ" >&2
fi

echo "== done. verify with dut_audit.sh =="
