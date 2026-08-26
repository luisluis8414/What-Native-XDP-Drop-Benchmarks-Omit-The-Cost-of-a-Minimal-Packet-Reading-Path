#!/usr/bin/env bash
# dut_measure_window.sh -- bracket one perf window with NIC/path snapshots.
#
# Runs on the DuT as root, normally staged and invoked by run_cell.sh. Keeping
# both snapshots and perf in this one process removes management-network
# round-trips from the packet-counter window.
#
#   dut_measure_window.sh IFACE CPU DUR PATH MODE PATH_HELPER NOPERF
set -uo pipefail

IFACE="${1:?missing interface}"
CPU="${2:?missing measurement CPU}"
DUR="${3:?missing duration}"
PATH_NAME="${4:?missing path name}"
MODE="${5:?missing XDP mode}"
PATH_HELPER="${6:?missing path helper}"
NOPERF="${7:-0}"

snapshot() {
  local phase=$1 t0 t1 stats nic cnt

  t0=$(date +%s.%N) || return 1
  stats=$(ethtool -S "$IFACE" 2>/dev/null) || return 1
  cnt=$(bash "$PATH_HELPER" count "$PATH_NAME" "$IFACE" "$MODE" 2>/dev/null) \
    || return 1
  t1=$(date +%s.%N) || return 1

  nic=$(awk '
    $1=="rx_packets:"       { rx=$2; have_rx=1 }
    $1=="rx_missed_errors:" { miss=$2; have_miss=1 }
    $1=="tx_packets:"       { tx=$2; have_tx=1 }
    END {
      if (!(have_rx && have_miss && have_tx)) exit 1
      printf "%s %s %s", rx, miss, tx
    }
  ' <<<"$stats") || return 1

  [[ "$nic" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] || return 1
  [[ "$cnt" =~ ^-?[0-9]+$ ]] || return 1
  [[ "$t0" =~ ^[0-9]+\.[0-9]+$ && "$t1" =~ ^[0-9]+\.[0-9]+$ ]] || return 1

  printf 'XDP3_SNAP_%s\t%s %s %s\n' "$phase" "$nic" "$cnt" "$t0 $t1"
}

snapshot START || {
  echo "XDP3_ERROR: opening counter snapshot failed" >&2
  exit 1
}

if [ "$NOPERF" = 1 ]; then
  taskset -c 0 sleep "$DUR"
  measure_rc=$?
else
  taskset -c 0 perf stat -x, -C "$CPU" \
    -e cycles,instructions,branch-misses,r0143,r0243,r0843,msr/aperf/,msr/mperf/,msr/tsc/ \
    -- taskset -c 0 sleep "$DUR" 2>&1
  measure_rc=$?
fi

# Take the closing snapshot before formatting or reading any ancillary state.
# This makes the counter window differ from perf only by local command startup,
# teardown and the two snapshot brackets.
snapshot END || {
  echo "XDP3_ERROR: closing counter snapshot failed" >&2
  exit 1
}

cpu_khz=0
if [ "$NOPERF" != 1 ]; then
  for source in scaling_cur_freq cpuinfo_cur_freq scaling_max_freq cpuinfo_max_freq; do
    value=$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/"$source" 2>/dev/null)
    if [ -n "$value" ] && [ "$value" -gt 0 ] 2>/dev/null; then
      cpu_khz=$value
      break
    fi
  done
fi
printf 'XDP3_CPU_KHZ\t%s\n' "$cpu_khz"
printf 'XDP3_MEASURE_RC\t%s\n' "$measure_rc"
exit "$measure_rc"
