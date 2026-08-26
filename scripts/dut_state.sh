#!/usr/bin/env bash
# dut_state.sh -- print the per-cell DuT measurement state as key<TAB>value
# lines. Runs ON the DuT, normally staged there by run_cell.sh.
#
#   dut_state.sh <iface> <cpu>
#
# run_cell.sh captures this once before and once after every cell and compares
# the two. `manifest.sh` records the environment once per campaign, which cannot
# show a setting that drifts mid-sweep. The snapshot includes settings known to
# reset here, most notably queue IRQ affinity after a native XDP attach. It also
# records the complete offload, software-steering and idle-state configuration
# needed to substantiate the measurement setup for each cell.
#
# Two prefixes:
#   set.*  must be identical before and after a cell. A difference invalidates it.
#   err.*  counters, expected to change. Recorded for the record, never compared.
set -uo pipefail

IFACE="${1:-enp35s0f1}"
CPU="${2:-10}"

p() { printf '%s\t%s\n' "$1" "${2:-}"; }

p set.combined_queues   "$(ethtool -l "$IFACE" 2>/dev/null | awk '/^Current/{f=1} f&&/Combined:/{print $2; exit}')"
p set.pause             "$(ethtool -a "$IFACE" 2>/dev/null | awk '/RX:/{r=$2} /TX:/{t=$2} END{print r"/"t}')"
p set.coalesce_rx_usecs "$(ethtool -c "$IFACE" 2>/dev/null | awk '/rx-usecs:/{print $2; exit}')"
p set.ring_rx           "$(ethtool -g "$IFACE" 2>/dev/null | awk '/^Current/{f=1} f&&/^RX:/{print $2; exit}')"
p set.governor          "$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_governor 2>/dev/null)"
p set.max_khz           "$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_max_freq 2>/dev/null)"
p set.boost             "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
p set.smt               "$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)"
p set.link              "$(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null)"
p set.bpf_stats         "$(cat /proc/sys/kernel/bpf_stats_enabled 2>/dev/null)"
# Enabling the hard-lockup detector takes one of the six core counters away and
# forces perf to multiplex the six events of a cell. Bracketed as a set.* key so
# a switch during a campaign invalidates the affected cells instead of silently
# turning their counts into extrapolations.
p set.nmi_watchdog      "$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)"

# Record every feature reported by the driver, not only the short list that
# dut_prepare.sh requests by ethtool shorthand. This preserves both the on/off
# state and qualifiers such as "[fixed]" in each per-cell sidecar. Sanitising
# the feature name keeps every entry in the set.* namespace, so run_cell.sh also
# detects a feature that changes during the cell.
ethtool -k "$IFACE" 2>/dev/null | awk '
  {
    line=$0
    sub(/^[[:space:]]+/, "", line)
    sep=index(line, ": ")
    if (!sep) next
    name=substr(line, 1, sep-1)
    value=substr(line, sep+2)
    if (value !~ /^(on|off)([[:space:]]|$)/) next
    gsub(/[^[:alnum:]]+/, "_", name)
    sub(/^_+/, "", name)
    sub(/_+$/, "", name)
    printf "set.offload.%s\t%s\n", name, value
  }
'

# RPS is configured per RX queue, while RFS also has a global flow-table size.
# Iterate over the queues that actually exist instead of assuming rx-0. The
# queue name is part of the key, which makes a queue appearing or disappearing
# visible as state drift in addition to the combined-queue count above.
for QDIR in /sys/class/net/"$IFACE"/queues/rx-*; do
  [ -d "$QDIR" ] || continue
  QNAME=$(basename "$QDIR")
  p "set.rps.${QNAME}.cpus"     "$(cat "$QDIR/rps_cpus" 2>/dev/null)"
  p "set.rps.${QNAME}.flow_cnt" "$(cat "$QDIR/rps_flow_cnt" 2>/dev/null)"
done
p set.rfs.sock_flow_entries "$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null)"

# cpuidle state numbers and names are platform dependent. Capture every state
# and its disable flag so the sidecar proves which states existed and whether
# each deep state was disabled for the measurement core. The active driver and
# governor identify the mechanism that interprets those state entries.
p set.cpuidle.driver   "$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)"
p set.cpuidle.governor "$(cat /sys/devices/system/cpu/cpuidle/current_governor_ro 2>/dev/null)"
for SDIR in /sys/devices/system/cpu/cpu"$CPU"/cpuidle/state*; do
  [ -d "$SDIR" ] || continue
  SNAME=$(basename "$SDIR")
  p "set.cpuidle.${SNAME}.name"    "$(cat "$SDIR/name" 2>/dev/null)"
  p "set.cpuidle.${SNAME}.disable" "$(cat "$SDIR/disable" 2>/dev/null)"
done

IRQ=$(grep -i "${IFACE}-TxRx-0" /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1;exit}')
p set.irq               "${IRQ:-none}"
p set.irq_eff_affinity  "$(cat /proc/irq/"${IRQ:-none}"/effective_affinity_list 2>/dev/null)"

# The instantaneous clock is informational: it is read outside the traffic
# window, where the core is idle, so it may legitimately differ from max_khz.
p err.cur_khz_at_capture "$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_cur_freq 2>/dev/null)"

stats=$(ethtool -S "$IFACE" 2>/dev/null)
for c in rx_crc_errors rx_missed_errors rx_no_buffer_count rx_length_errors \
         rx_over_errors rx_fifo_errors tx_errors rx_pause tx_pause; do
  v=$(awk -v k="$c:" '$1==k{print $2; exit}' <<<"$stats")
  p "err.$c" "${v:-na}"
done
