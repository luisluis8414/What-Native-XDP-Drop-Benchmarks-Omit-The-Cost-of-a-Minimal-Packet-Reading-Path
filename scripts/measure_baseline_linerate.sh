#!/usr/bin/env bash
# measure_baseline_linerate.sh -- the first measurement of the paper's procedure.
#
# It answers one binary question. Can the cheapest evaluated configuration, the
# unconditional native XDP drop, be driven into CPU saturation on a 10 GbE link?
#
# The answer decides how the whole results section reads. If the configuration
# saturates the core, its per-packet cost is directly observable and every more
# expensive configuration is CPU limited at the line rate as well. If it instead
# forwards the full line rate without loss, the link bounds it, and the cost can
# only be reported as an upper bound.
#
# A single rate cannot show a plateau, so this script does not classify a curve.
# It decides the binary question from three facts measured at the line rate:
# whether the DuT loses packets, whether the core still has idle cycles, and
# whether the generator really delivered the rate. The last one matters most.
# An under-delivering generator would make a CPU limited DuT look link limited.
#
# The reported rate is the overload plateau, not the RFC 2544 throughput. The
# highest loss-free rate is a different quantity and needs the offered-load
# sweep to establish.
#
# Prerequisites: DuT prepared (dut_prepare.sh -> dut_audit.sh ALL OK) and TRex
# running (trex_start.sh). This script does not start or stop TRex.
#
# Usage:
#   scripts/measure_baseline_linerate.sh --plan
#   scripts/measure_baseline_linerate.sh
#
# Options (defaults in []):
#   --pps N [14880952]     64 B line rate of the 10 GbE link
#   --duration S [30]      measured steady window, matches the campaign
#   --warmup S [5]         excluded warm-up per repetition
#   --reps N [5]
#   --touch no-touch|read-data|parse-ip|swap-macs [no-touch]  no-touch is cheapest
#   --skip-health-check
#   --iface IFACE [enp35s0f1]  --cpu N [10]
#   --host USER@HOST [dut@192.168.137.50]  --port N [1]
#   --label NAME  --outdir DIR  --plan
set -uo pipefail

LINE_RATE=14880952
PPS=$LINE_RATE
DUR=30
WARMUP=5
REPS=5
TOUCH=no-touch
SKIP_HC=0
IFACE=enp35s0f1
CPU=10
HOST=dut@192.168.137.50
PORT=1
LABEL=""
OUTDIR=""
PLAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pps) PPS=$2; shift 2 ;;
    --duration) DUR=$2; shift 2 ;;
    --warmup) WARMUP=$2; shift 2 ;;
    --reps) REPS=$2; shift 2 ;;
    --touch) TOUCH=$2; shift 2 ;;
    --skip-health-check) SKIP_HC=1; shift ;;
    --iface) IFACE=$2; shift 2 ;;
    --cpu) CPU=$2; shift 2 ;;
    --host) HOST=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --outdir) OUTDIR=$2; shift 2 ;;
    --plan) PLAN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$TOUCH" in no-touch|read-data|parse-ip|swap-macs) ;; *) echo "bad --touch: $TOUCH (xdp-bench -p values)" >&2; exit 2 ;; esac
[ "$REPS" -ge 1 ] 2>/dev/null || { echo "ERROR: --reps must be >= 1" >&2; exit 2; }
[ "$PPS" -le "$LINE_RATE" ] 2>/dev/null \
  || { echo "ERROR: --pps above the $LINE_RATE pps line rate; the generator refuses it" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LABEL="${LABEL:-xdp_drop_linerate_$TS}"
RUN_DIR="${OUTDIR:-$REPO/data/baseline/$LABEL}"
CELL_DIR="$RUN_DIR/cells"

if [ "$PLAN" = 1 ]; then
  echo "path=xdp_drop touch=$TOUCH"
  echo "offered_pps=$PPS (line rate $LINE_RATE)"
  echo "repetitions=$REPS duration_s=$DUR warmup_s=$WARMUP"
  echo "output=$RUN_DIR"
  echo "estimated_runtime_min=$(awk -v n="$REPS" -v d="$DUR" 'BEGIN{printf "%.0f", n*(d+25)/60}')"
  exit 0
fi

[ ! -e "$RUN_DIR" ] || { echo "ERROR: output already exists: $RUN_DIR" >&2; exit 2; }
ss -ltnH 2>/dev/null | grep -q ':4501' \
  || { echo "ERROR: TRex is not running; run scripts/trex_start.sh" >&2; exit 1; }
ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" \
  "for i in \$(seq 1 20); do [ \"\$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)\" = up ] && exit 0; sleep 1; done; exit 1" \
  || { echo "ERROR: DuT link $IFACE did not settle" >&2; exit 1; }

if [ "$SKIP_HC" = 0 ]; then
  echo "== health check: dut_audit =="
  ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" \
    "sudo bash -s -- $IFACE $CPU" < "$REPO/scripts/dut_audit.sh" \
    || { echo "ERROR: DuT isolation failed" >&2; exit 1; }
fi

mkdir -p "$CELL_DIR"
"$REPO/scripts/manifest.sh" --iface "$IFACE" --cpu "$CPU" --host "$HOST" \
  > "$RUN_DIR/manifest.json" || { echo "ERROR: provenance manifest failed" >&2; exit 1; }

python3 - "$RUN_DIR/campaign.json" "$PPS" "$LINE_RATE" "$REPS" "$DUR" "$WARMUP" \
  "$TOUCH" "$IFACE" "$CPU" "$HOST" "$PORT" <<'PY'
import datetime as dt, json, sys
out, pps, line, reps, dur, warm, touch, iface, cpu, host, port = sys.argv[1:]
json.dump({
    'created_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
    'purpose': 'decide whether the unconditional native XDP drop is CPU limited '
               'or link limited at the 10 GbE line rate',
    'paper_step': 'Measurement Procedure, first measurement',
    'path': 'xdp_drop', 'touch': touch,
    'rates_pps': [int(pps)], 'line_rate_pps': int(line),
    'repetitions_per_rate': int(reps), 'duration_s': int(dur), 'warmup_s': int(warm),
    'iface': iface, 'cpu': int(cpu), 'host': host, 'trex_port': int(port),
}, open(out, 'w'), indent=2)
open(out, 'a').write('\n')
PY

SUMMARY="$RUN_DIR/summary.tsv"
printf 'rep\toffered_pps\tdut_rx\tdut_missed\tmeasured_s\taccepted_pps\tbench_rate\tloss\tconservation\toerrors\ttx_leak\tperf_cpu_util\tcycles_per_pkt\tinstructions_per_pkt\trc\tfile\n' > "$SUMMARY"

echo "== baseline at line rate: $LABEL =="
echo "   path=xdp_drop touch=$TOUCH offered=$PPS pps reps=$REPS window=${DUR}s"

failures=0
for rep in $(seq 1 "$REPS"); do
  printf '[%d/%d] ... ' "$rep" "$REPS"
  output=$("$REPO/scripts/run_cell.sh" --path xdp_drop --touch "$TOUCH" \
    --pps "$PPS" --duration "$DUR" --warmup "$WARMUP" --iface "$IFACE" \
    --cpu "$CPU" --host "$HOST" --port "$PORT" --outdir "$CELL_DIR" 2>&1)
  rc=$?
  file=$(printf '%s\n' "$output" | sed -n 's/^-- saved: //p' | tail -1)
  if [ "$rc" -eq 0 ] && [ -n "$file" ] && [ -f "$file" ]; then
    row=$(python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print('\t'.join(str(d.get(k, 0)) for k in (
    'offered_pps_avg', 'dut_rx_pkts', 'dut_rx_missed', 'measured_s',
    'accepted_pps', 'bench_rate_median', 'loss_fraction',
    'conservation_ratio', 'trex_oerrors', 'dut_tx_pkts_whole_run',
    'perf_cpu_util', 'cycles_per_pkt',
    'instructions_per_pkt')))
PY
)
    printf '%s\t%s\t0\t%s\n' "$rep" "$row" "$file" >> "$SUMMARY"
    printf '%s\n' "$output" | grep -E '^-- (accepted|WARNING)' | sed 's/^-- /   /'
  else
    failures=$((failures + 1))
    printf '%s' "$rep" >> "$SUMMARY"
    printf '\tNA%.0s' $(seq 1 14) >> "$SUMMARY"
    printf '\t%s\t\n' "$rc" >> "$SUMMARY"
    echo "FAILED (rc=$rc)" >&2
    printf '%s\n' "$output" | tail -3 >&2
  fi
done

python3 - "$SUMMARY" "$RUN_DIR/analysis.txt" "$PPS" "$LINE_RATE" "$REPS" <<'PY'
import csv, statistics as st, sys
summary, analysis, offered, line, expected = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
rows = [r for r in csv.DictReader(open(summary), delimiter='\t') if r['rc'] == '0']
if not rows:
    sys.exit('ERROR: every repetition failed; nothing to decide')

def col(name):
    return [float(r[name]) for r in rows]

def med(name):
    return st.median(col(name))

acc, cpp = col('accepted_pps'), col('cycles_per_pkt')
loss, util = med('loss'), med('perf_cpu_util')
acc_med, cpp_med = st.median(acc), st.median(cpp)
cpp_range = 100 * (max(cpp) - min(cpp)) / cpp_med if cpp_med else 0
acc_range = 100 * (max(acc) - min(acc)) / acc_med if acc_med else 0
gen = med('offered_pps')
errs = sum(int(float(r['oerrors'])) for r in rows)
bench = med('bench_rate')

out = []
w = out.append
w('UNCONDITIONAL XDP DROP AT THE LINE RATE')
w('')
w(f'offered {offered} pps, line rate {line} pps, {len(rows)} of {expected} repetitions valid')
w('')
w(f"generator sampled rate      {gen/1e6:10.4f} Mpps   ({100*gen/line:.2f} per cent of line, {errs} transmit errors)")
w(f"DuT accepted                {acc_med/1e6:10.4f} Mpps   (min {min(acc)/1e6:.4f}, max {max(acc)/1e6:.4f}, range {acc_range:.3f} per cent)")
if bench > 0:
    w(f"xdp-bench reported          {bench/1e6:10.4f} Mpps   (the program's own view of the drop rate)")
w(f"RX-side loss                {100*loss:10.3f} per cent")
w(f"active cycle fraction       {100*util:10.2f} per cent")
w(f"cycles per packet           {cpp_med:10.1f}        (min {min(cpp):.1f}, max {max(cpp):.1f}, range {cpp_range:.3f} per cent)")
w(f"instructions per packet     {med('instructions_per_pkt'):10.1f}")

if len(rows) != expected:
    w('')
    w(f"WARNING: only {len(rows)} of {expected} repetitions produced a valid result.")

text = '\n'.join(out) + '\n'
open(analysis, 'w').write(text)
print()
print(text)
PY

echo "-- raw cells: $CELL_DIR"
echo "-- campaign:  $RUN_DIR/campaign.json"
echo "-- written:   $SUMMARY, $RUN_DIR/analysis.txt"
[ "$failures" -eq 0 ] || { echo "WARNING: $failures of $REPS repetitions failed" >&2; exit 1; }
