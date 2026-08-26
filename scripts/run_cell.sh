#!/usr/bin/env bash
# run_cell.sh -- run ONE measurement cell end-to-end from the tester.
#
# A cell is one (configuration, offered load) pair. The script installs the path on the
# DuT, verifies that it and only it is active, offers a fixed load with TRex,
# counts hardware events on the measurement core over the steady window, reads
# every counter on both sides, checks packet conservation, tears the path down
# and writes a JSON result.
#
# Configuration (see scripts/dut_path.sh):
#   xdp_drop       xdp-bench drop, attach mode selected with --mode
#
# Prereqs: DuT prepared (dut_prepare.sh -> dut_audit.sh ALL OK) and TRex running
# (trex_start.sh). This script does NOT start or stop TRex.
#
# Usage:
#   scripts/run_cell.sh --path xdp_drop --pps 14000000 --duration 30
#   scripts/run_cell.sh --path xdp_drop --mode skb --pps 1500000 --duration 30
#
# Options (defaults in []):
#   --path   xdp_drop
#   --pps    N                          [2000000]
#   --duration S                        [15]    measured steady window
#   --warmup S                          [2]     excluded in-window warm-up
#   --mode   native|skb  [native]       XDP attach point.
#            native runs inside the ixgbe driver before an skb exists. skb runs
#            at the generic hook, after the kernel has built the skb and has
#            already touched the packet headers.
#   --touch  no-touch|read-data|parse-ip|swap-macs  [no-touch]  (xdp_drop only)
#            passed straight to xdp-bench -p. The accepted values are those of
#            the xdp-bench on the DuT, which differ between xdp-tools releases.
#   --no-perf                           throughput only, skip cost metrics.
#            The DuT still gets an idle SSH session pinned to CPU 0 for the same
#            window, so a run with and without counters differs in the counters
#            alone and nothing else.
#   --validate-cpu-activity             run the one-time bpftrace isolation check
#   --iface  IFACE  [enp35s0f1]   --cpu N [10]
#   --host   user@host [dut@192.168.137.50]   --port TRex port [1]
#   --outdir DIR    [data/runs]
set -uo pipefail

PATH_NAME=xdp_drop PPS=2000000 DUR=15 WARMUP=2 TOUCH=no-touch MODE=native
IFACE=enp35s0f1 CPU=10 HOST=dut@192.168.137.50 PORT=1 OUTDIR="" NOPERF=0
VALIDATE_CPU_ACTIVITY=0
while [ $# -gt 0 ]; do case "$1" in
  --path) PATH_NAME=$2; shift 2;; --pps) PPS=$2; shift 2;;
  --duration) DUR=$2; shift 2;; --warmup) WARMUP=$2; shift 2;;
  --touch) TOUCH=$2; shift 2;; --mode) MODE=$2; shift 2;;
  --no-perf) NOPERF=1; shift;;
  --validate-cpu-activity) VALIDATE_CPU_ACTIVITY=1; shift;;
  --iface) IFACE=$2; shift 2;; --cpu) CPU=$2; shift 2;;
  --host) HOST=$2; shift 2;; --port) PORT=$2; shift 2;;
  --outdir) OUTDIR=$2; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;; esac; done

case "$PATH_NAME" in
  xdp_drop) ;;
  *) echo "bad --path: $PATH_NAME" >&2; exit 2;;
esac
case "$MODE" in
  native|skb) ;;
  *) echo "bad --mode: $MODE (native|skb)" >&2; exit 2;;
esac
IS_XDP=1
MODE_JSON=$MODE

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="${OUTDIR:-$REPO/data/runs}"
# Unique unit name per cell: journalctl -u <name> returns the FULL history for a
# unit name, so a shared name would pool every prior cell's rate lines into this
# cell's median. A per-process name also avoids start/stop name-collision races.
UNIT="xdpbench-cell-$$"
# The test interface carries an address, so its own stack emits a few packets per
# run (neighbour discovery and similar). Those are not packets escaping the drop
# path, which would be counted in millions. Tolerate background chatter, flag
# anything that could be a real leak.
TX_TOLERANCE=1000
# Frozen validity bands, see the Metrics and Analysis section of the paper. A
# cell that leaves them is not a noisy measurement, it is a broken one.
BAND_LO=0.995
BAND_HI=1.005
REMOTE_PATH_SH=/tmp/xdp3_path_$$.sh
REMOTE_STATE_SH=/tmp/xdp3_state_$$.sh
REMOTE_WINDOW_SH=/tmp/xdp3_measure_window_$$.sh
REMOTE_ACTIVITY_SH=/tmp/xdp3_cpu_activity_$$.sh
SSH=(ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=3 -o ServerAliveCountMax=3 "$HOST")
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUTDIR"

TPID=""
TJSON=""
TERR=""
ACTIVITY_PID=""
ACTIVITY_JSON_FILE=""
ACTIVITY_ERR_FILE=""

cleanup() {
  if [ -n "$TPID" ] && kill -0 "$TPID" 2>/dev/null; then
    kill "$TPID" 2>/dev/null || true
    wait "$TPID" 2>/dev/null || true
  fi
  if [ -n "$ACTIVITY_PID" ] && kill -0 "$ACTIVITY_PID" 2>/dev/null; then
    kill "$ACTIVITY_PID" 2>/dev/null || true
    wait "$ACTIVITY_PID" 2>/dev/null || true
  fi
  "${SSH[@]}" "sudo systemctl stop $UNIT 2>/dev/null; sudo systemctl reset-failed $UNIT 2>/dev/null; \
    sudo bash $REMOTE_PATH_SH clear none $IFACE 2>/dev/null; \
    rm -f $REMOTE_PATH_SH $REMOTE_STATE_SH $REMOTE_WINDOW_SH $REMOTE_ACTIVITY_SH" 2>/dev/null || true
  rm -f "${TJSON:-}" "${TERR:-}" "${ACTIVITY_JSON_FILE:-}" "${ACTIVITY_ERR_FILE:-}"
}
die() { echo "ERROR: $*" >&2; cleanup; exit 1; }

# Upload each helper through SSH because the DuT does not expose an SCP/SFTP
# subsystem. Keeping the helpers remote avoids an extra transfer per snapshot.
upload() { "${SSH[@]}" "cat > $2" < "$1"; }
upload "$REPO/scripts/dut_path.sh" "$REMOTE_PATH_SH" \
  || die "could not upload dut_path.sh to the DuT"
upload "$REPO/scripts/dut_state.sh" "$REMOTE_STATE_SH" \
  || die "could not upload dut_state.sh to the DuT"
upload "$REPO/scripts/dut_measure_window.sh" "$REMOTE_WINDOW_SH" \
  || die "could not upload dut_measure_window.sh to the DuT"
if [ "$VALIDATE_CPU_ACTIVITY" = 1 ]; then
  upload "$REPO/scripts/dut_cpu_activity.sh" "$REMOTE_ACTIVITY_SH" \
    || die "could not upload dut_cpu_activity.sh to the DuT"
fi
dutpath() { "${SSH[@]}" "sudo bash $REMOTE_PATH_SH $1 ${2:-} $IFACE $MODE"; }
dutstate() { "${SSH[@]}" "sudo bash $REMOTE_STATE_SH $IFACE $CPU"; }

# Native XDP attach/detach reinitializes the ixgbe rings and briefly bounces the
# DAC link. Poll (DuT-side, single SSH round-trip) until it is up again.
wait_link_up() {
  "${SSH[@]}" "for i in \$(seq 1 ${1:-20}); do \
    [ \"\$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)\" = up ] && exit 0; sleep 1; done; exit 1"
}

echo "== cell: path=$PATH_NAME mode=$MODE pps=$PPS warmup=${WARMUP}s measure=${DUR}s touch=$TOUCH =="

# Preflight: kill orphaned benches first. An interrupted cell can leave its
# xdp-bench unit running with its program still attached. Path verification only
# checks that an XDP program is attached, not whose it is, so an orphan would
# pass the check and this cell would measure a program it did not start. In a
# long campaign a single interrupted cell would poison every cell after it.
ORPHANS=$("${SSH[@]}" "systemctl list-units --all --no-legend 'xdpbench-cell-*' 2>/dev/null | awk '{print \$1}' | grep -v '^$UNIT\\.service$'" 2>/dev/null)
if [ -n "$ORPHANS" ]; then
  echo "   clearing $(printf '%s\n' "$ORPHANS" | grep -c .) orphaned bench unit(s) from an earlier run"
  "${SSH[@]}" "sudo systemctl stop 'xdpbench-cell-*' 2>/dev/null; sudo systemctl reset-failed 'xdpbench-cell-*' 2>/dev/null" >/dev/null 2>&1
fi

# Remove every path's state, then wait for the link (a prior cell's detach may
# still be bouncing it).
dutpath clear none >/dev/null || die "preflight clear failed"
wait_link_up 20 || die "DuT $IFACE link did not come up (preflight)"

# Install the path. xdp-bench remains active as a transient service.
if [ "$PATH_NAME" = xdp_drop ]; then
  BENCH="xdp-bench drop $IFACE -m $MODE -p $TOUCH -i 1"
  "${SSH[@]}" "sudo systemctl reset-failed $UNIT 2>/dev/null; sudo systemd-run --unit=$UNIT --collect $BENCH" >/dev/null 2>&1 \
    || die "systemd-run failed to launch: $BENCH"
  sleep 3
  [ "$("${SSH[@]}" "systemctl is-active $UNIT" 2>/dev/null)" = active ] \
    || die "unit $UNIT not active (bench crashed?): $("${SSH[@]}" "journalctl -u $UNIT -o cat --no-pager | tail -3")"
else
  dutpath install "$PATH_NAME" >/dev/null || die "could not install path $PATH_NAME"
fi

# Verify from the installed state, never from throughput: exactly this path is
# active, the other five are not, and no conntrack is in the way.
VERIFY=$(dutpath verify "$PATH_NAME" 2>&1) || die "path verification failed: $VERIFY"
echo "   path verified: $VERIFY"

# The attach itself bounced the link (native ixgbe); wait for it before traffic.
wait_link_up 20 || die "link did not recover after installing the path"

# ixgbe can restore RX/TX PAUSE when an XDP attach reinitializes the adapter.
# ethtool -A returns before that reinitialization and link recovery have fully
# settled, so an immediate query can still report the old on/on state. Apply the
# setting after every attach and poll both the requested state and carrier. A
# cell must never start with backpressure enabled when overload is supposed to
# appear as rx_missed_errors.
if ! PAUSE_STATE=$("${SSH[@]}" "sudo ethtool -A $IFACE autoneg off rx off tx off || exit 1; \
  for i in \$(seq 1 20); do \
    p=\$(ethtool -a $IFACE 2>/dev/null | awk '\$1==\"RX:\"{r=\$2} \$1==\"TX:\"{t=\$2} END{print r\"/\"t}'); \
    link=\$(cat /sys/class/net/$IFACE/operstate 2>/dev/null); \
    [ \"\$p\" = off/off ] && [ \"\$link\" = up ] && { echo \"\$p\"; exit 0; }; \
    sleep 1; \
  done; \
  echo \"\${p:-unknown}\"; exit 1"); then
  die "could not disable RX/TX PAUSE after attach (final state: ${PAUSE_STATE:-unknown})"
fi
echo "   flow control disabled: $PAUSE_STATE"
# The flow-control change reinitializes ixgbe as well. Confirm that the program
# and requested hook survived that second reset before pinning the new queue IRQ.
VERIFY_AFTER_PAUSE=$(dutpath verify "$PATH_NAME" 2>&1) \
  || die "path verification failed after disabling PAUSE: $VERIFY_AFTER_PAUSE"

# A native XDP attach reinitializes the ixgbe rings and RESETS the queue IRQ
# affinity to the driver default (the housekeeping mask, which excludes the
# isolated core). dut_prepare's pin is therefore clobbered by the attach, moving
# RX processing off cpu$CPU. Re-pin here, AFTER the install, and verify the
# EFFECTIVE affinity (not just the requested list) actually lands on cpu$CPU --
# otherwise perf would measure an idle core and the run is invalid. The filter
# paths do not reinitialize the rings, but the same check is cheap and guards
# against an unrelated reset.
EFF=$("${SSH[@]}" "irq=\$(grep -i '${IFACE}-TxRx-0' /proc/interrupts | awk -F: '{gsub(/ /,\"\",\$1);print \$1;exit}'); \
  [ -n \"\$irq\" ] && { echo $CPU | sudo tee /proc/irq/\$irq/smp_affinity_list >/dev/null; cat /proc/irq/\$irq/effective_affinity_list; }")
[ "$EFF" = "$CPU" ] || die "queue IRQ effective affinity is '$EFF', not cpu$CPU -- RX is not on the measurement core"
echo "   queue IRQ pinned: effective cpu$EFF"

# Bracket the cell: capture the drift-prone settings now, with the path already
# installed, and again after the traffic window. The campaign manifest is written
# once per sweep and therefore cannot show a setting that changes between cells.
STATE_PRE=$(dutstate) || die "could not capture the DuT state before the cell"

# Counter snapshot: NIC receive and overflow establish offered-packet
# conservation, the egress counter must stay flat (a DROP path transmits
# nothing), and the path counter is the path's own view of what it discarded.
# The receive counters are bracketed by two DuT timestamps. A rate divides a
# counter delta by an elapsed time, so the instant of the counter read has to be
# known, not just the counter value. Reading the clock after the remaining
# commands would put a variable sudo and fork delay between the two, and that
# delay does not cancel between the opening and the closing snapshot. The
# midpoint of the bracket estimates the read instant and its width bounds the
# residual error.
snap() { "${SSH[@]}" "t0=\$(date +%s.%N); \
  rx=\$(ethtool -S $IFACE 2>/dev/null | awk '/rx_packets:/{p=\$2} /rx_missed_errors:/{m=\$2} END{print p+0, m+0}'); \
  t1=\$(date +%s.%N); \
  tx=\$(ethtool -S $IFACE 2>/dev/null | awk '/tx_packets:/{p=\$2} END{print p+0}'); \
  cnt=\$(sudo bash $REMOTE_PATH_SH count $PATH_NAME $IFACE $MODE 2>/dev/null); \
  echo \"\$rx \$tx \${cnt:--1} \$t0 \$t1\""; }

# Populate SNAP_* or abort the cell at the first missing counter snapshot. An
# empty SSH result must never be coerced to zero and turned into an epoch-sized
# measurement window.
take_snap() {
  local phase=$1 raw
  if ! raw=$(snap); then
    die "$phase counter snapshot failed: management SSH to $HOST did not respond"
  fi
  parse_snap "$phase" "$raw"
}

# Parse a snapshot produced either by snap() or by the single-session steady
# window helper. Keeping one validator prevents the two paths from accepting
# different counter formats.
parse_snap() {
  local phase=$1 raw=$2
  if ! [[ "$raw" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ -?[0-9]+\ [0-9]+\.[0-9]+\ [0-9]+\.[0-9]+$ ]]; then
    die "$phase counter snapshot is incomplete: '${raw:-<empty>}'"
  fi
  read -r SNAP_RX SNAP_MISS SNAP_TX SNAP_CNT SNAP_T0 SNAP_T1 <<<"$raw"
  # Midpoint of the bracket as the estimated read instant, width as its bound.
  read -r SNAP_TIME SNAP_TSPAN < <(awk -v a="$SNAP_T0" -v b="$SNAP_T1" \
    'BEGIN{printf "%.9f %.6f", (a+b)/2, b-a}')
}

# In-window warm-up: run traffic for (warmup + measure + tail); take the measured
# counters only AFTER the warm-up, so the cold install/ramp is excluded. Traffic
# runs in the background so we can snapshot mid-run. One remote helper takes the
# opening snapshot, runs `perf stat -- sleep DUR`, and immediately takes the
# closing snapshot in the same SSH session. The packet-counter window therefore
# differs from the perf window only by local command startup, teardown and the
# two snapshot brackets. The tail keeps traffic flowing through that margin.
TAIL=4
TOTAL=$((WARMUP + DUR + TAIL))
TJSON=$(mktemp)
TERR=$(mktemp)
( cd "$REPO" && python3 scripts/trex/smoke_stream.py --pps "$PPS" --duration "$TOTAL" --port "$PORT" >"$TJSON" 2>"$TERR" ) &
TPID=$!

take_snap "whole-run start"
RXS=$SNAP_RX; MISSS=$SNAP_MISS; TXS=$SNAP_TX; CNTS=$SNAP_CNT
sleep "$WARMUP"
if [ "$VALIDATE_CPU_ACTIVITY" = 1 ]; then
  ACTIVITY_JSON_FILE=$(mktemp)
  ACTIVITY_ERR_FILE=$(mktemp)
  "${SSH[@]}" "sudo bash $REMOTE_ACTIVITY_SH --cpu $CPU --housekeeping-cpu 0 --iface $IFACE --duration $DUR" \
    >"$ACTIVITY_JSON_FILE" 2>"$ACTIVITY_ERR_FILE" &
  ACTIVITY_PID=$!
fi
# aperf, mperf and tsc turn the active fraction into a ratio of two counters
# from the same window. tsc ticks always, mperf ticks at the same rate but only
# while the core is awake, so mperf/tsc is the awake fraction and needs no
# assumed clock. aperf/mperf recovers the real core clock per window.
# PMCx043 (Core::X86::Pmc::Core::LsRefillsFromSys) splits every demand data
# cache fill by where it came from. The three masks are documented in
# data/artifacts/pmc043_mask_mapping_20260823.md. Family 17h has six programmable
# core counters, all used here. The msr events use a separate PMU.

# The helper emits marker records around the ordinary perf CSV. Its command
# runs as root because perf and the path counter need privilege. Crucially, SSH
# returns only after both snapshots have already been taken on the DuT.
if ! WINDOW_RAW=$("${SSH[@]}" "sudo bash $REMOTE_WINDOW_SH $IFACE $CPU $DUR $PATH_NAME $MODE $REMOTE_PATH_SH $NOPERF"); then
  die "steady measurement failed: $(printf '%s\n' "${WINDOW_RAW:-<no output>}" | tail -3 | tr '\n' ' ')"
fi
START_RAW=$(printf '%s\n' "$WINDOW_RAW" | awk -F'\t' '$1=="XDP3_SNAP_START"{print $2; n++} END{if(n!=1)exit 1}') \
  || die "steady measurement returned no unique opening snapshot"
END_RAW=$(printf '%s\n' "$WINDOW_RAW" | awk -F'\t' '$1=="XDP3_SNAP_END"{print $2; n++} END{if(n!=1)exit 1}') \
  || die "steady measurement returned no unique closing snapshot"
CPU_KHZ=$(printf '%s\n' "$WINDOW_RAW" | awk -F'\t' '$1=="XDP3_CPU_KHZ"{print $2; n++} END{if(n!=1)exit 1}') \
  || die "steady measurement returned no unique CPU frequency"
MEASURE_RC=$(printf '%s\n' "$WINDOW_RAW" | awk -F'\t' '$1=="XDP3_MEASURE_RC"{print $2; n++} END{if(n!=1)exit 1}') \
  || die "steady measurement returned no unique exit status"
[ "$MEASURE_RC" = 0 ] || die "steady measurement command exited with status $MEASURE_RC"
PERF=$(printf '%s\n' "$WINDOW_RAW" | awk -F'\t' \
  '$1!="XDP3_SNAP_START" && $1!="XDP3_SNAP_END" && $1!="XDP3_CPU_KHZ" && $1!="XDP3_MEASURE_RC"')

parse_snap "steady-window start" "$START_RAW"
RX0=$SNAP_RX; MISS0=$SNAP_MISS; TX0=$SNAP_TX; CNT0=$SNAP_CNT; T0=$SNAP_TIME; SPAN0=$SNAP_TSPAN
parse_snap "steady-window end" "$END_RAW"
RX1=$SNAP_RX; MISS1=$SNAP_MISS; TX1=$SNAP_TX; CNT1=$SNAP_CNT; T1=$SNAP_TIME; SPAN1=$SNAP_TSPAN
CPU_ACTIVITY_FIELD=""
CPU_ACTIVITY_CLEAN=""
if [ "$VALIDATE_CPU_ACTIVITY" = 1 ]; then
  if ! wait "$ACTIVITY_PID"; then
    ACTIVITY_ERROR=$(cat "$ACTIVITY_ERR_FILE")
    rm -f "$ACTIVITY_JSON_FILE" "$ACTIVITY_ERR_FILE"
    die "CPU activity check failed: $ACTIVITY_ERROR"
  fi
  ACTIVITY_PID=""
  CPU_ACTIVITY=$(cat "$ACTIVITY_JSON_FILE")
  rm -f "$ACTIVITY_JSON_FILE" "$ACTIVITY_ERR_FILE"
  ACTIVITY_JSON_FILE=""; ACTIVITY_ERR_FILE=""
  CPU_ACTIVITY_CLEAN=$(printf '%s' "$CPU_ACTIVITY" | python3 -c \
    'import json,sys; print("true" if json.load(sys.stdin).get("clean") is True else "false")') \
    || die "CPU activity output is not valid JSON"
  CPU_ACTIVITY_FIELD=$(printf ',\n  "cpu_activity": %s' "$CPU_ACTIVITY")
fi
if ! wait "$TPID"; then
  TPID=""
  TREX_ERROR=$(cat "$TERR")
  die "TRex traffic process failed: ${TREX_ERROR:-no diagnostic output}"
fi
TPID=""
take_snap "whole-run end"
RXE=$SNAP_RX; MISSE=$SNAP_MISS; TXE=$SNAP_TX; CNTE=$SNAP_CNT
STATE_POST=$(dutstate) || die "could not capture the DuT state after the cell"
# Only the set.* keys must hold. The err.* counters are expected to move and are
# kept for the record. Compare both key sets as well as their values. This is
# necessary for enumerated state such as RX queues, NIC features and cpuidle
# states, where a disappearing entry is itself a state change.
STATE_CHANGED=$(awk -F'\t' '
  NR==FNR {
    if ($1 ~ /^set\./) pre[$1]=$2
    next
  }
  $1 ~ /^set\./ {
    post[$1]=$2
    if (!($1 in pre)) printf "%s(<missing>->%s) ", $1, $2
    else if (pre[$1] != $2) printf "%s(%s->%s) ", $1, pre[$1], $2
  }
  END {
    for (key in pre)
      if (!(key in post)) printf "%s(%s-><missing>) ", key, pre[key]
  }
' <(printf '%s\n' "$STATE_PRE") <(printf '%s\n' "$STATE_POST"))
STATE_STABLE=true; [ -z "$STATE_CHANGED" ] || STATE_STABLE=false
TREX_JSON=$(cat "$TJSON"); rm -f "$TJSON" "$TERR"; TJSON=""; TERR=""
[ -n "$TREX_JSON" ] || die "no TRex output (server running? conda deactivated?)"

# Parse perf CSV: field 1 = value, 3 = event, 4 = runtime_ns (from the cycles
# line -> the exact counting window in seconds). `+0` coerces "<not counted>" to 0.
# Field 5 is the share of the window an event was actually counting. Anything
# below 100 means perf multiplexed the events and every value is an estimate.
read -r CYC INS BMISS FL2 FCCX FDRAM APERF MPERF TSCC PSEC MINRUN < <(printf '%s\n' "$PERF" | awk -F, '
  function note(v){ if($5!="" && $5+0<m) m=$5+0 }
  BEGIN{m=100}
  $3=="cycles"{c=$1; r=$4; note()} $3=="instructions"{i=$1; note()}
  $3=="branch-misses"{bm=$1; note()}
  $3=="r0143"{f2=$1; note()} $3=="r0243"{fc=$1; note()} $3=="r0843"{fd=$1; note()}
  $3=="msr/aperf/"{ap=$1; note()} $3=="msr/mperf/"{mp=$1; note()}
  $3=="msr/tsc/"{ts=$1; note()}
  END{printf "%d %d %d %d %d %d %d %d %d %.4f %.2f",
      c+0, i+0, bm+0, f2+0, fc+0, fd+0, ap+0, mp+0, ts+0, (r+0)/1e9, m}')
# Fail loud: a silent cyc=0/khz=0 cell would write a zero-cost JSON that the
# sweep then averages into the curve. cycles/packet is the primary metric, so a
# missing perf sample invalidates the whole cell -- abort instead of recording 0.
if [ "$NOPERF" != 1 ]; then
  [ "${CYC:-0}" -gt 0 ] || die "perf returned no cycles (PMU busy / counters unavailable / core idle): $(printf '%s' "$PERF" | head -1)"
  [ "${CPU_KHZ:-0}" -gt 0 ] 2>/dev/null || die "no valid CPU frequency for cpu$CPU -- ns/pkt and util would be bogus"
  awk -v m="${MINRUN:-0}" 'BEGIN{exit !(m >= 99.9)}' \
    || die "perf multiplexed the events (lowest run share ${MINRUN}%) -- counters are estimates, not measurements"
  [ "${TSCC:-0}" -gt 0 ] && [ "${MPERF:-0}" -gt 0 ] && [ "${APERF:-0}" -gt 0 ] \
    || die "msr aperf/mperf/tsc returned no value -- load the msr module or run with --no-perf"
  # cycles and aperf both count core clocks while the core is awake, but they
  # disagree by roughly ten clocks on every wake from halt. Below saturation the
  # core sleeps between interrupt batches, so the gap grows to a few per cent of
  # an already small total and says nothing about the measurement. At and near
  # saturation the core stops sleeping and the two agree to parts per million.
  # Enforce the check only where it carries information, and record the ratio in
  # every cell either way.
  AWAKE=$(awk -v m="${MPERF:-0}" -v t="${TSCC:-0}" 'BEGIN{printf "%.4f", (t>0)?m/t:0}')
  CYCAPERF=$(awk -v c="${CYC:-0}" -v a="${APERF:-0}" 'BEGIN{printf "%.4f", (a>0)?c/a:0}')
  if awk -v w="$AWAKE" 'BEGIN{exit !(w > 0.90)}'; then
    awk -v r="$CYCAPERF" 'BEGIN{exit !(r > 0.98 && r < 1.02)}' \
      || die "cycles and aperf disagree by a factor of $CYCAPERF while the core is $AWAKE awake -- clock accounting is not understood"
  fi
fi

# Steady-state DuT rate from the bench journal (xdp-bench only).
if [ "$PATH_NAME" = xdp_drop ]; then
  RATE=$("${SSH[@]}" "journalctl -u $UNIT -o cat --no-pager" 2>/dev/null | \
    grep -oE '[0-9,]+ rx/s' | tr -d ', ' | sed 's|rx/s||' | \
    awk '$1>0' | sort -n | \
    awk '{a[n++]=$1} END{if(n==0)print 0; else if(n%2)print a[(n-1)/2]; else print int((a[n/2-1]+a[n/2])/2)}')
else
  RATE=0
fi

cleanup

# Derive metrics. accepted/loss come from the STEADY sub-window (C0->C1, actual
# elapsed dt); conservation is a whole-run generator<->DuT cross-check.
# tx_pps_avg is a sampled rate and dips at the run edges. The offered rate that
# the loss fraction is divided by must be exact, so derive it from the transmit
# counter and the traffic duration instead.
read -r OFFERED TXPPS OERR OFFPPS < <(echo "$TREX_JSON" | python3 -c 'import sys,json
d=json.load(sys.stdin)
dur=float(d["duration_s"])
print(d["tx_pkts"], d["tx_pps_avg"], d["oerrors"], (int(d["tx_pkts"])/dur) if dur else 0)')
RESULT=$(awk -v rx0="$RX0" -v rx1="$RX1" -v m0="$MISS0" -v m1="$MISS1" \
  -v tx0="$TX0" -v tx1="$TX1" -v c0="$CNT0" -v c1="$CNT1" \
  -v rxs="$RXS" -v rxe="$RXE" -v ms="$MISSS" -v me="$MISSE" -v txs="$TXS" -v txe="$TXE" \
  -v off="$OFFERED" -v t0="$T0" -v t1="$T1" -v khz="$CPU_KHZ" \
  -v cyc="$CYC" -v ins="$INS" -v bm="$BMISS" -v psec="$PSEC" \
  -v fl2="$FL2" -v fccx="$FCCX" -v fdram="$FDRAM" \
  -v offpps="$OFFPPS" \
  -v ap="$APERF" -v mp="$MPERF" -v tsc="$TSCC" 'BEGIN{
  dt=t1-t0; drx=rx1-rx0; dtx=tx1-tx0; dmiss=m1-m0; win=drx+dmiss;
  acc=(dt>0)?drx/dt:0; lossrx=(win>0)?(dmiss/win):0;
  # The paper defines pre-XDP loss against the offered load, following
  # parola2023comparing. TRex offers a constant rate, so the packets offered
  # during the steady window are that rate times the window. lossrx divides by
  # what arrived instead and is kept for the record.
  offwin=offpps*dt; loss=(offwin>0)?(dmiss/offwin):0;
  seen=(rxe-rxs)+(me-ms); cons=(off>0)?(seen/off):0;
  # The path counter is what the path itself reports as dropped. A ratio far
  # below 1 means the packets were not discarded where we think they were, for
  # example a filter rule that does not match the generated stream. -1 marks a
  # path that keeps no counter of its own.
  dcnt=(c0>=0 && c1>=0)?(c1-c0):-1;
  pathratio=(dcnt>=0 && drx>0)?(dcnt/drx):-1;
  # A DROP path must not transmit. Anything here means packets escaped the path.
  dtxall=txe-txs;
  # Per-packet cost: cycles counted over the perf window (psec) divided by the
  # packets processed in that window (accepted rate x psec). The rate comes from
  # NIC snapshots that bracket perf in the same DuT process, so management SSH
  # latency is outside both ends of the counter window.
  pkts=(psec>0)?(acc*psec):drx;
  cpp=(pkts>0)?(cyc/pkts):0; ipp=(pkts>0)?(ins/pkts):0;
  bmpp=(pkts>0)?(bm/pkts):0;
  # Demand data cache fills per packet, split by source. Their sum is every
  # fill the packet cost, so l2+ccx+dram is the quantity the generic
  # cache-misses event used to approximate without naming a level.
  fl2pp=(pkts>0)?(fl2/pkts):0; fccxpp=(pkts>0)?(fccx/pkts):0;
  fdrampp=(pkts>0)?(fdram/pkts):0;
  ipc=(cyc>0)?(ins/cyc):0;
  # The awake fraction is a ratio of two counters from the same window. tsc
  # ticks unconditionally, mperf ticks at the same rate but only while the core
  # is awake. No assumed clock enters, so the nominal-versus-real frequency
  # question does not arise here.
  perfutil=(tsc>0)?(mp/tsc):0;
  # Real core clock: the tsc rate scaled by the ratio of real to reference
  # clocks. aperf counts real core clocks while awake, mperf counts reference
  # clocks over the same awake time.
  tschz=(psec>0)?(tsc/psec):0;
  corehz=(mp>0)?(tschz*ap/mp):0;
  # The declared sysfs frequency is kept only so the record shows both.
  declhz=khz*1000;
  freqdev=(declhz>0 && corehz>0)?(corehz/declhz):0;
  coreghz=corehz/1e9; nspp=(coreghz>0)?(cpp/coreghz):0;
  printf "%d %d %d %d %d %.3f %.1f %.6f %.6f %.4f %.4f %.4f %.2f %.2f %.4f %.3f %.2f %.0f %.0f %.6f %.4f %.4f %.4f",
    drx, dtx, dmiss, dcnt, dtxall, dt, acc, loss, lossrx, cons, pathratio, perfutil,
    cpp, ipp, bmpp, ipc, nspp, corehz, tschz, freqdev, fl2pp, fccxpp, fdrampp;
}')
read -r DRX DTX DMISS DCNT DTXALL DT ACCPPS LOSS LOSSRX CONS PATHRATIO PERFUTIL CPP IPP BMPP IPC NSPP COREHZ TSCHZ FREQDEV FL2PP FCCXPP FDRAMPP <<<"$RESULT"

# A cell that accepts packets while the measurement core stays idle did not
# measure the path under test. The usual cause is a DuT that was never prepared,
# where RSS spreads the traffic over every core and cpu$CPU sees almost nothing.
# Campaign wrappers run dut_audit.sh first and would catch that, but a bare
# run_cell.sh does not, and the resulting JSON looks like a result.
#
# The check needs the active-cycle fraction, which only exists when perf ran. A
# --no-perf cell has no utilisation measure at all, and a missing measure must
# not be read as an idle core: that would fail every uninstrumented cell of the
# instrumentation comparison.
if [ "$NOPERF" = 0 ]; then
  awk -v a="$ACCPPS" -v u="$PERFUTIL" 'BEGIN{exit !(a > 100000 && u < 0.01)}' \
    && die "accepted $(awk -v a=$ACCPPS 'BEGIN{printf "%.3f", a/1e6}') Mpps while cpu$CPU was $(awk -v u=$PERFUTIL 'BEGIN{printf "%.2f", 100*u}')% busy -- the traffic is not being processed on the measurement core. Run dut_prepare.sh and dut_audit.sh."
else
  echo "-- note: no counters in this mode, the idle-core check is skipped"
fi

# The steady window opens after the warm-up, so it may last at most (DUR + TAIL)
# before it runs past the end of the generated traffic. A window that overruns
# would count a silent tail as measured time and understate the accepted rate,
# without any counter reporting an error. Both durations are measured on the DuT
# clock, so no clock skew enters the comparison.
awk -v dt="$DT" -v lim="$((DUR + TAIL))" 'BEGIN{exit !(dt <= lim)}' \
  || die "counter window ${DT}s exceeds the traffic window $((DUR + TAIL))s -- the measured rate would be understated; raise TAIL or the duration"
WINDOW_OVERHEAD=$(awk -v dt="$DT" -v p="$PSEC" 'BEGIN{printf "%.3f", dt-p}')
if [ "$NOPERF" = 1 ]; then
  WINDOW_METHOD=same_dut_session_bracketing_control_sleep
else
  WINDOW_METHOD=same_dut_session_bracketing_perf
fi
# The true read instants lie inside their brackets, so the error of the counter
# window is at most half of each bracket. Record the bound with the result.
WINDOW_UNCERT=$(awk -v a="${SPAN0:-0}" -v b="${SPAN1:-0}" 'BEGIN{printf "%.6f", (a+b)/2}')

# Validity verdict against the frozen criteria. These were warnings before, which
# meant every later analysis had to re-implement them from the raw fields and
# none of them did it the same way. The verdict now travels with the cell.
INVALID_REASONS=()
outside() { awk -v v="$1" -v lo="$BAND_LO" -v hi="$BAND_HI" \
  'BEGIN{exit !(v<lo || v>hi)}'; }
if [ "$OFFERED" -gt 0 ] 2>/dev/null && outside "$CONS"; then
  INVALID_REASONS+=("conservation_ratio $CONS outside $BAND_LO..$BAND_HI")
fi
if awk -v v="$PATHRATIO" 'BEGIN{exit !(v>=0)}' && outside "$PATHRATIO"; then
  INVALID_REASONS+=("path_drop_ratio $PATHRATIO outside $BAND_LO..$BAND_HI")
fi
if [ "$DTXALL" -gt "$TX_TOLERANCE" ] 2>/dev/null; then
  INVALID_REASONS+=("dut transmitted $DTXALL packets, above $TX_TOLERANCE")
fi
if [ "$STATE_STABLE" != true ]; then
  INVALID_REASONS+=("dut settings changed: $STATE_CHANGED")
fi
if [ "${OERR:-0}" -gt 0 ] 2>/dev/null; then
  INVALID_REASONS+=("trex reported $OERR transmit errors")
fi
# Below 100 means perf multiplexed the events and every counter is an estimate.
# Only meaningful when perf ran at all.
if [ "$NOPERF" = 0 ] && awk -v v="${MINRUN:-0}" 'BEGIN{exit !(v<100)}'; then
  INVALID_REASONS+=("perf counters ran only ${MINRUN:-0}% of the window")
fi
if [ "${#INVALID_REASONS[@]}" -eq 0 ]; then VALID=true; else VALID=false; fi
REASONS_JSON=$(printf '%s\n' "${INVALID_REASONS[@]+"${INVALID_REASONS[@]}"}" \
  | awk 'NF{gsub(/"/,"\\\""); printf "%s\"%s\"", (n++?", ":""), $0}')

# Emit result JSON.
JQ=$(cat <<EOF
{
  "ts": "$TS",
  "path": "$PATH_NAME", "touch": "$TOUCH", "mode": "$MODE_JSON",
  "iface": "$IFACE", "cpu": $CPU,
  "requested_pps": $PPS, "warmup_s": $WARMUP, "duration_s": $DUR, "measured_s": $DT,
  "offered_pkts": $OFFERED, "offered_pps_avg": $TXPPS, "trex_oerrors": $OERR,
  "dut_rx_pkts": $DRX, "dut_tx_pkts": $DTX, "dut_rx_missed": $DMISS,
  "path_dropped_pkts": $DCNT, "path_drop_ratio": $PATHRATIO,
  "dut_tx_pkts_whole_run": $DTXALL,
  "accepted_pps": $ACCPPS, "bench_rate_median": $RATE,
  "loss_fraction": $LOSS, "loss_fraction_rx": $LOSSRX,
  "conservation_ratio": $CONS,
  "valid": $VALID, "invalid_reasons": [$REASONS_JSON],
  "perf_cpu_util": $PERFUTIL,
  "cpu_khz": ${CPU_KHZ:-0}, "perf_window_s": $PSEC,
  "core_hz_measured": ${COREHZ:-0}, "tsc_hz_measured": ${TSCHZ:-0},
  "core_hz_vs_declared": ${FREQDEV:-0},
  "aperf": ${APERF:-0}, "mperf": ${MPERF:-0}, "tsc": ${TSCC:-0},
  "perf_min_run_pct": ${MINRUN:-0}, "cycles_vs_aperf": ${CYCAPERF:-0},
  "counter_window_s": $DT, "window_overhead_s": $WINDOW_OVERHEAD,
  "counter_window_method": "$WINDOW_METHOD",
  "counter_window_uncertainty_s": ${WINDOW_UNCERT:-0}$CPU_ACTIVITY_FIELD,
  "state_stable": $STATE_STABLE, "state_changed": "$(printf '%s' "$STATE_CHANGED" | sed 's/"/\\"/g')",
  "cycles": $CYC, "instructions": $INS, "branch_misses": $BMISS,
  "cycles_per_pkt": $CPP, "instructions_per_pkt": $IPP, "ns_per_pkt": $NSPP,
  "branch_misses_per_pkt": $BMPP, "ipc": $IPC,
  "fills_lcl_l2": $FL2, "fills_lcl_cache": $FCCX, "fills_lcl_dram": $FDRAM,
  "fills_lcl_l2_per_pkt": $FL2PP, "fills_lcl_cache_per_pkt": $FCCXPP,
  "fills_lcl_dram_per_pkt": $FDRAMPP,
  "pmc043_masks": "r0143=0x01 lcl_l2, r0243=0x02 lcl_cache, r0843=0x08 lcl_dram",
  "cache_misses": -1, "cache_misses_per_pkt": -1
}
EOF
)
FILE="$OUTDIR/${TS}_${PATH_NAME}_${PPS}.json"
# Recreate the output directory: it is made once at start-up, and a long cell
# gives an operator ample time to remove it in between. A cell that cannot
# persist its result must fail rather than report success, because the summary
# line below would otherwise announce a measurement that exists nowhere.
mkdir -p "$OUTDIR" || die "cannot create output directory $OUTDIR"
echo "$JQ" > "$FILE" || die "could not write the result to $FILE"
[ -s "$FILE" ] || die "result file $FILE is empty after writing"
# Sidecar provenance: the captured state itself, not just the verdict, so a later
# question about this cell can be answered from the record.
STATE_FILE="$OUTDIR/${TS}_${PATH_NAME}_${PPS}.state"
{ echo "# before"; printf '%s\n' "$STATE_PRE"; echo "# after"; printf '%s\n' "$STATE_POST"; } \
  > "$STATE_FILE" || die "could not write the state sidecar to $STATE_FILE"
echo "$JQ"
awk -v a="$ACCPPS" -v l="$LOSS" -v c="$CONS" -v o="$OERR" -v cpp="$CPP" \
    -v pu="$PERFUTIL" -v ns="$NSPP" 'BEGIN{
  printf "-- accepted ~%.3f Mpps, loss %.3f%%, cons %.3f, perf cpu %.1f%%, %.1f cyc/pkt (%.1f ns), oerrors %s\n",
    a/1e6, l*100, c, pu*100, cpp, ns, o;
}'
if [ "$VALID" != true ]; then
  printf -- '-- INVALID CELL, do not use in the analysis:\n'
  printf -- '     %s\n' "${INVALID_REASONS[@]}"
fi
if [ "$VALIDATE_CPU_ACTIVITY" = 1 ] && [ "$CPU_ACTIVITY_CLEAN" != true ]; then
  echo "-- WARNING: foreign task or interrupt activity reached cpu$CPU"
fi
echo "-- saved: $FILE"
