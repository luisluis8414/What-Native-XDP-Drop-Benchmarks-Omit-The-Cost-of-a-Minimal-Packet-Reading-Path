#!/usr/bin/env bash
# Verify the final DUT runtime state, including the state after native XDP
# attach and the per-cell IRQ re-pin. Run on the DUT as root.
#
#   final_dut_audit.sh <iface> <cpu> [expected-rx-ring]
set -uo pipefail

IFACE="${1:-enp35s0f1}"
CPU="${2:-10}"
EXPECTED_RX_RING="${3:-4096}"
[[ "$EXPECTED_RX_RING" =~ ^[1-9][0-9]*$ ]] \
  || { echo "invalid expected RX ring: $EXPECTED_RX_RING" >&2; exit 2; }
UNIT=xdpbench-final-audit
fail=0

value() { printf '%-34s %s\n' "$1" "$2"; }
check() {
  value "$1" "$3"
  if [ "$2" != "$3" ]; then
    printf 'FAIL %-29s expected %s\n' "$1" "$2" >&2
    fail=1
  fi
}

cleanup() {
  systemctl stop "$UNIT" 2>/dev/null || true
  systemctl reset-failed "$UNIT" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

cleanup
value captured_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

kernel=$(uname -r)
check kernel 7.0.0-22-generic "$kernel"

driver_info=$(ethtool -i "$IFACE")
bus=$(awk -F': ' '/^bus-info:/{print $2}' <<<"$driver_info")
check nic_bus 0000:23:00.1 "$bus"
pcie=$(lspci -vv -s "$bus" 2>/dev/null | awk -F'LnkSta:' '/LnkSta:/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
check pcie_link 'Speed 5GT/s, Width x8' "$pcie"

link_info=$(ethtool "$IFACE" 2>/dev/null)
speed=$(awk -F': ' '/^[ \t]*Speed:/{print $2}' <<<"$link_info")
duplex=$(awk -F': ' '/^[ \t]*Duplex:/{print $2}' <<<"$link_info")
detected=$(awk -F': ' '/^[ \t]*Link detected:/{print $2}' <<<"$link_info")
check link_speed 10000Mb/s "$speed"
check link_duplex Full "$duplex"
check link_detected yes "$detected"

combined=$(ethtool -l "$IFACE" 2>/dev/null | awk '/^Current/{f=1} f&&/Combined:/{print $2; exit}')
ring_info=$(ethtool -g "$IFACE" 2>/dev/null)
ring_rx=$(awk '/^Current hardware settings:/{f=1;next} f&&/^RX:/{print $2;exit}' <<<"$ring_info")
ring_tx=$(awk '/^Current hardware settings:/{f=1;next} f&&/^TX:/{print $2;exit}' <<<"$ring_info")
coalesce=$(ethtool -c "$IFACE" 2>/dev/null)
rx_usecs=$(awk '/^rx-usecs:/{print $2;exit}' <<<"$coalesce")
tx_usecs=$(awk '/^tx-usecs:/{print $2;exit}' <<<"$coalesce")
pause=$(ethtool -a "$IFACE" 2>/dev/null | awk '/RX:/{r=$2} /TX:/{t=$2} END{print r"/"t}')
check combined_queues 1 "$combined"
check ring_rx "$EXPECTED_RX_RING" "$ring_rx"
check ring_tx 4096 "$ring_tx"
check coalesce_rx_usecs 1 "$rx_usecs"
check coalesce_tx_usecs 0 "$tx_usecs"
check flow_control off/off "$pause"

features=$(ethtool -k "$IFACE" 2>/dev/null)
feature() { awk -F': ' -v key="$1" '$1==key{print $2;exit}' <<<"$features" | awk '{print $1}'; }
for name in rx-checksumming scatter-gather tcp-segmentation-offload \
            generic-segmentation-offload generic-receive-offload \
            large-receive-offload rx-vlan-offload tx-vlan-offload; do
  check "feature_$name" off "$(feature "$name")"
done

rps_cpus=$(cat /sys/class/net/"$IFACE"/queues/rx-0/rps_cpus)
rps_flow=$(cat /sys/class/net/"$IFACE"/queues/rx-0/rps_flow_cnt)
rfs_entries=$(cat /proc/sys/net/core/rps_sock_flow_entries)
check rps_cpus 000 "$rps_cpus"
check rps_flow_count 0 "$rps_flow"
check rfs_socket_entries 0 "$rfs_entries"

check isolcpus 10-11 "$(cat /sys/devices/system/cpu/isolated)"
check nohz_full 10-11 "$(cat /sys/devices/system/cpu/nohz_full)"
check governor performance "$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_governor)"
max_khz=$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_max_freq)
cur_khz=$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_cur_freq)
check cpu_max_khz 3200000 "$max_khz"
check cpu_current_khz "$max_khz" "$cur_khz"
check boost 0 "$(cat /sys/devices/system/cpu/cpufreq/boost)"
check smt off "$(cat /sys/devices/system/cpu/smt/control)"
check online_cpus 0,2,4,6,8,10 "$(cat /sys/devices/system/cpu/online)"
check cpu10_c2_disabled 1 "$(cat /sys/devices/system/cpu/cpu"$CPU"/cpuidle/state2/disable)"
check bpf_stats_enabled 0 "$(cat /proc/sys/kernel/bpf_stats_enabled)"
check bpf_jit_enable 1 "$(cat /proc/sys/net/core/bpf_jit_enable)"

irqbalance=$(systemctl is-active irqbalance 2>/dev/null || true)
check irqbalance inactive "$irqbalance"
nf_conntrack=$(lsmod | grep -c '^nf_conntrack' || true)
check nf_conntrack_loaded 0 "$nf_conntrack"
legacy_rules=$(iptables-legacy -t raw -S PREROUTING 2>/dev/null | grep -vc '^-P ' || true)
nft_rules=$(iptables-nft -t raw -S PREROUTING 2>/dev/null | grep -vc '^-P ' || true)
nft_tables=$(nft list tables 2>/dev/null | grep -c . || true)
check legacy_raw_rules 0 "$legacy_rules"
check iptables_nft_raw_rules 0 "$nft_rules"
check nft_tables 0 "$nft_tables"

systemd-run --unit="$UNIT" --collect \
  xdp-bench drop "$IFACE" -m native -p no-touch -i 1 >/dev/null
sleep 3
check xdp_bench_unit active "$(systemctl is-active "$UNIT")"

for i in $(seq 1 20); do
  [ "$(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null)" = up ] && break
  sleep 1
done
check link_after_attach up "$(cat /sys/class/net/"$IFACE"/operstate)"
# Match run_cell.sh: ixgbe may restore PAUSE while native XDP reinitialises its
# rings, so disable it after attachment and confirm that both link and program
# survive the second reinitialisation.
ethtool -A "$IFACE" autoneg off rx off tx off
for i in $(seq 1 20); do
  pause_after=$(ethtool -a "$IFACE" 2>/dev/null | awk '/RX:/{r=$2} /TX:/{t=$2} END{print r"/"t}')
  [ "$pause_after" = off/off ] \
    && [ "$(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null)" = up ] && break
  sleep 1
done
check flow_control_after_attach off/off "${pause_after:-unknown}"
check link_after_pause_change up "$(cat /sys/class/net/"$IFACE"/operstate)"
mode=$(bpftool net show dev "$IFACE" | awk '/driver id/{print "driver";exit}')
check xdp_attach_mode driver "$mode"
prog_info=$(bpftool prog show name xdp_basic_prog)
value xdp_program "$(head -1 <<<"$prog_info")"
xlated=$(sed -n 's/.*xlated \([0-9][0-9]*\)B.*/\1/p' <<<"$prog_info")
jited=$(sed -n 's/.*jited \([0-9][0-9]*\)B.*/\1/p' <<<"$prog_info")
check xdp_xlated_bytes 304 "$xlated"
check xdp_jited_bytes 180 "$jited"

irq=$(grep -i "${IFACE}-TxRx-0" /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1;exit}')
value queue_irq "$irq"
value irq_effective_before_repin "$(cat /proc/irq/"$irq"/effective_affinity_list)"
echo "$CPU" > /proc/irq/"$irq"/smp_affinity_list
check irq_requested_after_repin "$CPU" "$(cat /proc/irq/"$irq"/smp_affinity_list)"
check irq_effective_after_repin "$CPU" "$(cat /proc/irq/"$irq"/effective_affinity_list)"

combined_after=$(ethtool -l "$IFACE" 2>/dev/null | awk '/^Current/{f=1} f&&/Combined:/{print $2; exit}')
ring_after=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^Current hardware settings:/{f=1;next} f&&/^RX:/{print $2;exit}')
coalesce_after=$(ethtool -c "$IFACE" 2>/dev/null | awk '/^rx-usecs:/{print $2;exit}')
check combined_queues_after_attach 1 "$combined_after"
check ring_rx_after_attach "$EXPECTED_RX_RING" "$ring_after"
check coalesce_rx_after_attach 1 "$coalesce_after"

cleanup
trap - EXIT HUP INT TERM
# Leave the interface in the campaign baseline after detach as well. The final
# audit is a readiness gate, so it should not itself leave PAUSE enabled.
ethtool -A "$IFACE" autoneg off rx off tx off
for i in $(seq 1 20); do
  pause_after_cleanup=$(ethtool -a "$IFACE" 2>/dev/null | awk '/RX:/{r=$2} /TX:/{t=$2} END{print r"/"t}')
  [ "$pause_after_cleanup" = off/off ] \
    && [ "$(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null)" = up ] && break
  sleep 1
done
xdp_after=$(bpftool net show dev "$IFACE" | awk '/xdp:/{getline; if ($0 !~ /^[[:space:]]*$/) print "attached"}')
check xdp_after_cleanup none "${xdp_after:-none}"
check flow_control_after_cleanup off/off "${pause_after_cleanup:-unknown}"
check link_after_cleanup up "$(cat /sys/class/net/"$IFACE"/operstate)"

if [ "$fail" -eq 0 ]; then
  echo 'RESULT                             ALL CHECKS PASSED'
else
  echo 'RESULT                             FAILURES PRESENT'
fi
exit "$fail"
