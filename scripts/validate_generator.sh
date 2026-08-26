#!/usr/bin/env bash
# validate_generator.sh -- establish the observed maximum generator rate and
# whether it reaches the 64 B line rate without transmit errors.
#
# This answers the first validity check of the paper. The claim under test is
# not "the DuT is fast enough" but "the generator actually put the requested
# packets on the wire". The authoritative number is therefore the TRex transmit
# packet counter over its own traffic duration, not a sampled rate. DuT NIC
# counters cross-check that the packets crossed the link.
#
# TRex validates the requested bandwidth against the port capability and refuses
# to start traffic that would exceed it. The offered load therefore cannot be
# pushed above the line rate at all. The script probes that boundary once and
# records the refusal, which establishes that the link and not the generator
# bounds every offered load in this study.
#
# The DuT runs xdp-filter as a sink. Any sink works for this test, because
# rx_packets plus rx_missed_errors counts every frame that arrived, whether or
# not the CPU processed it. A sink is still required: without one the stack
# would answer 14 Mpps of UDP with ICMP and pollute the reverse direction.
#
# Prerequisites: DuT prepared, TRex running. Does not start or stop TRex.
#
# Usage:
#   scripts/validate_generator.sh
#   scripts/validate_generator.sh --duration 60 --reps 5
#
# Options (defaults in []):
#   --rates CSV [14000000,14500000,14880952]   raw pps, at or below line rate
#   --duration S [30]     traffic duration per run
#   --reps N [3]
#   --sink xdp_filter|none [xdp_filter]
#   --iface IFACE [enp35s0f1]  --cpu N [10]
#   --host USER@HOST [dut@192.168.137.50]  --port N [1]
#   --outdir DIR   --plan
set -uo pipefail

LINE_RATE=14880952          # 64 B frames on 10 GbE, 84 B on the wire incl. IFG
RATES="14000000,14500000,14880952"
DUR=30
REPS=3
SINK=xdp_filter
IFACE=enp35s0f1
CPU=10
HOST=dut@192.168.137.50
PORT=1
OUTDIR=""
PLAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --rates) RATES=$2; shift 2 ;;
    --duration) DUR=$2; shift 2 ;;
    --reps) REPS=$2; shift 2 ;;
    --sink) SINK=$2; shift 2 ;;
    --iface) IFACE=$2; shift 2 ;;
    --cpu) CPU=$2; shift 2 ;;
    --host) HOST=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --outdir) OUTDIR=$2; shift 2 ;;
    --plan) PLAN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$SINK" in xdp_filter|none) ;; *) echo "bad --sink: $SINK" >&2; exit 2 ;; esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="${OUTDIR:-$REPO/data/validation/generator_$TS}"
SSH=(ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST")
REMOTE_PATH_SH=/tmp/xdp3_genpath_$$.sh

mapfile -t RATE_LIST < <(printf '%s' "$RATES" | tr ',' '\n' | sed '/^$/d')
[ "${#RATE_LIST[@]}" -ge 1 ] || { echo "ERROR: no rates given" >&2; exit 2; }
for r in "${RATE_LIST[@]}"; do
  [ "$r" -ge 10000 ] 2>/dev/null || { echo "ERROR: bad rate: $r" >&2; exit 2; }
done

if [ "$PLAN" = 1 ]; then
  echo "rates_pps=${RATE_LIST[*]}"
  echo "line_rate_pps=$LINE_RATE"
  echo "duration_s=$DUR reps=$REPS sink=$SINK"
  echo "runs=$((REPS * ${#RATE_LIST[@]})) output=$RUN_DIR"
  echo "estimated_runtime_min=$(awk -v n="$((REPS * ${#RATE_LIST[@]}))" -v d="$DUR" \
    'BEGIN{printf "%.0f", n*(d+8)/60}')"
  exit 0
fi

[ ! -e "$RUN_DIR" ] || { echo "ERROR: output already exists: $RUN_DIR" >&2; exit 2; }
ss -ltnH 2>/dev/null | grep -q ':4501' \
  || { echo "ERROR: TRex is not running; run scripts/trex_start.sh" >&2; exit 1; }

mkdir -p "$RUN_DIR"
SINK_INSTALLED=0
cleanup() {
  if [ "$SINK_INSTALLED" = 1 ]; then
    "${SSH[@]}" "sudo bash $REMOTE_PATH_SH clear none $IFACE" >/dev/null 2>&1 || true
  fi
  "${SSH[@]}" "rm -f $REMOTE_PATH_SH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "$SINK" != none ]; then
  "${SSH[@]}" "cat > $REMOTE_PATH_SH" < "$REPO/scripts/dut_path.sh" \
    || { echo "ERROR: could not upload dut_path.sh" >&2; exit 1; }
  "${SSH[@]}" "sudo bash $REMOTE_PATH_SH clear none $IFACE" >/dev/null 2>&1
  "${SSH[@]}" "sudo bash $REMOTE_PATH_SH install $SINK $IFACE" >/dev/null \
    || { echo "ERROR: could not install the sink $SINK" >&2; exit 1; }
  SINK_INSTALLED=1
  "${SSH[@]}" "for i in \$(seq 1 20); do [ \"\$(cat /sys/class/net/$IFACE/operstate)\" = up ] && exit 0; sleep 1; done; exit 1" \
    || { echo "ERROR: link did not come up after installing the sink" >&2; exit 1; }
  # Native XDP attachment can restore ixgbe PAUSE. Generator validation must
  # use the same no-backpressure link state as the campaign, otherwise NIC
  # overflow need not appear in rx_missed_errors. Apply and verify it only after
  # the attach and link recovery have settled.
  PAUSE=$("${SSH[@]}" "sudo ethtool -A $IFACE autoneg off rx off tx off || exit 1; \
    for i in \$(seq 1 20); do \
      p=\$(ethtool -a $IFACE 2>/dev/null | awk '\$1==\"RX:\"{r=\$2} \$1==\"TX:\"{t=\$2} END{print r\"/\"t}'); \
      link=\$(cat /sys/class/net/$IFACE/operstate 2>/dev/null); \
      [ \"\$p\" = off/off ] && [ \"\$link\" = up ] && { echo \"\$p\"; exit 0; }; \
      sleep 1; \
    done; echo \"\${p:-unknown}\"; exit 1") \
    || { echo "ERROR: could not disable PAUSE after installing $SINK" >&2; exit 1; }
  VERIFY=$("${SSH[@]}" "sudo bash $REMOTE_PATH_SH verify $SINK $IFACE native" 2>&1) \
    || { echo "ERROR: sink verification failed after disabling PAUSE: $VERIFY" >&2; exit 1; }
  echo "== sink installed: $SINK, PAUSE $PAUSE =="
fi

"$REPO/scripts/manifest.sh" --iface "$IFACE" --cpu "$CPU" --host "$HOST" \
  > "$RUN_DIR/manifest.json" || echo "WARNING: manifest failed" >&2

# rx_packets and rx_missed_errors together count every frame that arrived,
# including those the ring had no descriptor for.
snap() { "${SSH[@]}" "ethtool -S $IFACE | awk '/rx_packets:/{p=\$2} /rx_missed_errors:/{m=\$2} END{print p+0, m+0}'"; }

# One-shot ceiling probe. The expected outcome is a refusal, which is the
# evidence that the offered load cannot exceed the link. Two seconds is enough,
# because the rate is validated before any traffic starts.
PROBE_PPS=$((LINE_RATE + 500000))
PROBE_OUT="$RUN_DIR/ceiling_probe.txt"
echo "== ceiling probe: requesting $PROBE_PPS pps, above the line rate =="
( cd "$REPO" && python3 scripts/trex/smoke_stream.py --pps "$PROBE_PPS" --duration 2 --port "$PORT" ) \
  > "$PROBE_OUT" 2>&1
PROBE_RC=$?
if [ "$PROBE_RC" -ne 0 ] && grep -q 'exceeds port line rate' "$PROBE_OUT"; then
  echo "   refused by the generator, as expected"
elif [ "$PROBE_RC" -eq 0 ]; then
  echo "   WARNING: the generator accepted a request above the line rate"
else
  echo "   WARNING: the probe failed for an unrelated reason, see $PROBE_OUT"
fi

SUMMARY="$RUN_DIR/runs.tsv"
printf 'rep\trequested_pps\ttx_pkts\tduration_s\tachieved_pps\ttx_pps_avg\ttx_bps_L1\tport_util_pct\toerrors\tdut_rx\tdut_missed\tdut_seen\tcross_check\trc\n' > "$SUMMARY"

echo "== generator capacity: line rate for 64 B frames is $LINE_RATE pps =="
echo "   rates=${RATE_LIST[*]} duration=${DUR}s reps=$REPS"

total=$((REPS * ${#RATE_LIST[@]})); run=0; failures=0
for rep in $(seq 1 "$REPS"); do
  for requested in "${RATE_LIST[@]}"; do
    run=$((run + 1))
    printf '[%d/%d] rep=%d requested=%.4f Mpps ... ' "$run" "$total" "$rep" \
      "$(awk -v r="$requested" 'BEGIN{print r/1e6}')"
    read -r RX0 MISS0 <<<"$(snap)"
    # Keep stdout and stderr apart. The client prints progress lines that would
    # otherwise be spliced into the JSON and make a good run look like a failure.
    TOUT=$(mktemp); TERRF=$(mktemp)
    ( cd "$REPO" && python3 scripts/trex/smoke_stream.py --pps "$requested" \
      --duration "$DUR" --port "$PORT" ) > "$TOUT" 2> "$TERRF"
    rc=$?
    read -r RX1 MISS1 <<<"$(snap)"
    out=$(sed -n '/^{/,/^}/p' "$TOUT")
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
      failures=$((failures + 1))
      echo "FAILED (rc=$rc)"
      { tail -3 "$TERRF"; tail -3 "$TOUT"; } >&2
      rm -f "$TOUT" "$TERRF"
      printf '%s\t%s' "$rep" "$requested" >> "$SUMMARY"
      printf '\tNA%.0s' $(seq 1 11) >> "$SUMMARY"
      printf '\t%s\n' "$rc" >> "$SUMMARY"
      continue
    fi
    rm -f "$TOUT" "$TERRF"
    printf '%s\n' "$out" > "$RUN_DIR/run_${rep}_${requested}.json"
    row=$(printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rx0, m0, rx1, m1 = (int(x) for x in sys.argv[1:5])
tx = int(d["tx_pkts"]); dur = float(d["duration_s"])
seen = (rx1 - rx0) + (m1 - m0)
ach = tx / dur if dur else 0
print("\t".join(str(v) for v in [
    tx, dur, round(ach, 1), d["tx_pps_avg"], d["tx_bps_L1"],
    d["port_util_pct"], d["oerrors"], rx1 - rx0, m1 - m0, seen,
    round(seen / tx, 5) if tx else 0]))
' "$RX0" "$MISS0" "$RX1" "$MISS1")
    printf '%s\t%s\t%s\t0\n' "$rep" "$requested" "$row" >> "$SUMMARY"
    printf '%s\n' "$row" | awk -v line="$LINE_RATE" -F'\t' '{
      printf "sent %.4f Mpps (%.2f%% of line), oerrors %s, cross-check %.4f\n",
        $3/1e6, 100*$3/line, $7, $11 }'
  done
done

python3 - "$SUMMARY" "$RUN_DIR/analysis.txt" "$LINE_RATE" <<'PY'
import csv, statistics as st, sys
summary, analysis, line = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = [r for r in csv.DictReader(open(summary), delimiter='\t') if r['rc'] == '0']
if not rows:
    sys.exit('ERROR: every generator run failed')

by = {}
for r in rows:
    by.setdefault(int(r['requested_pps']), []).append(r)

out = []
w = out.append
w('GENERATOR CAPACITY')
w('')
w(f'64 B line rate on 10 GbE: {line} pps')
w('achieved_pps is the transmit packet counter divided by the traffic duration.')
w('cross_check is what the DuT NIC saw divided by what the generator sent.')
w('')
w(f"{'requested Mpps':>15} {'n':>2} {'achieved Mpps':>14} {'% of line':>10} "
  f"{'oerrors':>8} {'util %':>7} {'cross_check':>12}")
for rate in sorted(by):
    rs = by[rate]
    ach = [float(r['achieved_pps']) for r in rs]
    med = st.median(ach)
    w(f"{rate/1e6:15.4f} {len(rs):2d} {med/1e6:14.4f} {100*med/line:10.3f} "
      f"{max(int(r['oerrors']) for r in rs):8d} "
      f"{st.median([float(r['port_util_pct']) for r in rs]):7.2f} "
      f"{st.median([float(r['cross_check']) for r in rs]):12.5f}")

text = '\n'.join(out) + '\n'
open(analysis, 'w').write(text)
print()
print(text)
PY

echo "-- raw runs: $RUN_DIR"
echo "-- written:  $SUMMARY, $RUN_DIR/analysis.txt"
[ "$failures" -eq 0 ] || { echo "WARNING: $failures of $total runs failed" >&2; exit 1; }
