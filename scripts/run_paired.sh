#!/usr/bin/env bash
# run_paired.sh -- run the four-configuration block design of the paper.
#
# The paper crosses two packet operations (no-touch, read-data) with two XDP
# hooks (native, skb/generic). At each offered load all four configurations form
# one block and their order inside the block is randomised. Keeping both hooks
# in the same block prevents slow drift from landing entirely in the
# native-versus-generic difference of the two operation effects.
#
# Here the four-way block is the unit. All mode/variant combinations run
# back-to-back at the same load. One campaign block is a complete pass over every
# rate in shuffled order, so the repetitions of a rate are spread over the whole
# run rather than bunched into one window.
#
# The optional uninstrumented repetition answers InXpect: perf-based
# instrumentation can delay execution far enough for driver prefetching to
# complete and mask the very access under study. Counting on a core over a whole
# window should not do that, but the claim is testable rather than arguable. At
# the rates given to --uninstrumented-rates each block is repeated with the
# counters off. Masking would make the touch variant faster with the counters
# than without, so agreement between the two bounds the effect.
#
# Prerequisites: DuT prepared (dut_prepare.sh -> dut_audit.sh ALL OK) and TRex
# running (trex_start.sh). This script does NOT start or stop TRex.
#
# Usage:
#   scripts/run_paired.sh --rates 1m,2m,14m,14880952 --plan
#   scripts/run_paired.sh --rates 1m,2m,14m,14880952 \
#     --uninstrumented-rates 14m,14880952
#
# Options (defaults in []):
#   --rates CSV            required, the frozen offered-load grid
#   --variants A,B [no-touch,read-data]   xdp-bench -p values, exactly two
#   --uninstrumented-rates CSV []  rates that also get a counter-free block
#   --modes CSV [native,skb]  XDP attach points crossed with both variants.
#   --mode native|skb         compatibility alias for a one-hook sensitivity run
#   --expect-rx-ring N []  abort unless the RX ring is already N descriptors.
#            The ring is set once by the required RX-ring argument to
#            dut_prepare.sh, so a sensitivity campaign must assert that value.
#            This turns that into a refusal to start instead of lost hours.
#   --path NAME [xdp_drop]  --reps N [10]  --duration S [30]  --cell-warmup S [5]
#   --ordered              run rates and configurations in the order given
#   --skip-health-check    --iface IFACE [enp35s0f1]  --cpu N [10]
#   --host USER@HOST [dut@192.168.137.50]  --port N [1]
#   --label NAME  --outdir DIR  --plan
set -uo pipefail

PATH_NAME=xdp_drop
MODES="native,skb"
EXPECT_RING=""
VARIANTS="no-touch,read-data"
RATES=""
UNINST=""
REPS=10
DUR=30
CELLWARMUP=5
RANDOMISE=1
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
    --path) PATH_NAME=$2; shift 2 ;;
    --modes) MODES=$2; shift 2 ;;
    --mode) MODES=$2; shift 2 ;;
    --expect-rx-ring) EXPECT_RING=$2; shift 2 ;;
    --variants) VARIANTS=$2; shift 2 ;;
    --rates) RATES=$2; shift 2 ;;
    --uninstrumented-rates) UNINST=$2; shift 2 ;;
    --reps) REPS=$2; shift 2 ;;
    --duration) DUR=$2; shift 2 ;;
    --cell-warmup) CELLWARMUP=$2; shift 2 ;;
    --ordered) RANDOMISE=0; shift ;;
    --skip-health-check) SKIP_HC=1; shift ;;
    --plan) PLAN=1; shift ;;
    --iface) IFACE=$2; shift 2 ;;
    --cpu) CPU=$2; shift 2 ;;
    --host) HOST=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --label) LABEL=$2; shift 2 ;;
    --outdir) OUTDIR=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Only xdp-bench exposes the no-touch and read-data operations.
case "$PATH_NAME" in
  xdp_drop) ;;
  *) echo "bad --path: $PATH_NAME (the four-way design requires xdp_drop)" >&2; exit 2 ;;
esac
if [ -n "$EXPECT_RING" ]; then
  [ "$EXPECT_RING" -ge 64 ] 2>/dev/null \
    || { echo "ERROR: --expect-rx-ring must be a descriptor count" >&2; exit 2; }
fi
[ -n "$RATES" ] || { echo "ERROR: --rates is required; freeze the grid before the campaign" >&2; exit 2; }
[ "$REPS" -ge 1 ] 2>/dev/null || { echo "ERROR: --reps must be >= 1" >&2; exit 2; }
[ "$DUR" -ge 1 ] 2>/dev/null || { echo "ERROR: --duration must be positive" >&2; exit 2; }

mapfile -t VAR_LIST < <(printf '%s' "$VARIANTS" | tr ',' '\n' | sed '/^$/d')
[ "${#VAR_LIST[@]}" -eq 2 ] \
  || { echo "ERROR: --variants needs exactly two values, got ${#VAR_LIST[@]}" >&2; exit 2; }
[ "${VAR_LIST[0]}" != "${VAR_LIST[1]}" ] \
  || { echo "ERROR: the two variants are identical" >&2; exit 2; }
[ "$RANDOMISE" = 0 ] || command -v shuf >/dev/null \
  || { echo "ERROR: shuf is required for randomised blocks" >&2; exit 1; }

mapfile -t MODE_LIST < <(printf '%s' "$MODES" | tr ',' '\n' | sed '/^$/d')
[ "${#MODE_LIST[@]}" -ge 1 ] && [ "${#MODE_LIST[@]}" -le 2 ] \
  || { echo "ERROR: --modes needs one or two values" >&2; exit 2; }
seen_native=0
seen_skb=0
for mode in "${MODE_LIST[@]}"; do
  case "$mode" in
    native)
      [ "$seen_native" = 0 ] || { echo "ERROR: duplicate mode: native" >&2; exit 2; }
      seen_native=1
      ;;
    skb)
      [ "$seen_skb" = 0 ] || { echo "ERROR: duplicate mode: skb" >&2; exit 2; }
      seen_skb=1
      ;;
    *) echo "bad mode in --modes: $mode (native|skb)" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LABEL="${LABEL:-paired_${PATH_NAME}_${TS}}"
RUN_DIR="${OUTDIR:-$REPO/data/paired/$LABEL}"
CELL_DIR="$RUN_DIR/cells"
SUMMARY="$RUN_DIR/summary.tsv"
ANALYSIS="$RUN_DIR/analysis.txt"
[ ! -e "$RUN_DIR" ] || { echo "ERROR: output already exists: $RUN_DIR" >&2; exit 2; }

# Decimal 'm' values are accepted, the generator always receives integer pps.
normalise_rates() {
  python3 - "$1" <<'PY'
import sys
line = 14_880_952
seen = set()
for raw in sys.argv[1].split(','):
    token = raw.strip().lower()
    if not token:
        continue
    try:
        value = float(token[:-1]) * 1_000_000 if token.endswith('m') else float(token)
    except ValueError:
        raise SystemExit(f"invalid rate: {raw!r}")
    rate = round(value)
    if rate < 10_000 or rate > line:
        raise SystemExit(f"rate outside 10k..14,880,952 pps: {raw!r}")
    if rate in seen:
        raise SystemExit(f"duplicate rate after normalisation: {rate}")
    seen.add(rate)
    print(rate)
PY
}

RATE_TEXT=$(normalise_rates "$RATES") || exit 2
mapfile -t RATE_LIST <<< "$RATE_TEXT"
[ "${#RATE_LIST[@]}" -ge 1 ] || { echo "ERROR: no rates given" >&2; exit 2; }

UNINST_LIST=()
if [ -n "$UNINST" ]; then
  UNINST_TEXT=$(normalise_rates "$UNINST") || exit 2
  mapfile -t UNINST_LIST <<< "$UNINST_TEXT"
  # An uninstrumented rate that is not measured instrumented has nothing to be
  # compared against, which would silently produce a one-sided result.
  for u in "${UNINST_LIST[@]}"; do
    found=0
    for r in "${RATE_LIST[@]}"; do [ "$u" = "$r" ] && found=1 && break; done
    [ "$found" = 1 ] || { echo "ERROR: uninstrumented rate $u is not in --rates" >&2; exit 2; }
  done
fi

is_uninst() {
  for u in ${UNINST_LIST[@]+"${UNINST_LIST[@]}"}; do [ "$1" = "$u" ] && return 0; done
  return 1
}

CONFIGS_PER_BLOCK=$((${#MODE_LIST[@]} * ${#VAR_LIST[@]}))
INST_CELLS=$((REPS * ${#RATE_LIST[@]} * CONFIGS_PER_BLOCK))
UNINST_CELLS=$((REPS * ${#UNINST_LIST[@]} * CONFIGS_PER_BLOCK))
TOTAL=$((INST_CELLS + UNINST_CELLS))

if [ "$PLAN" = 1 ]; then
  echo "path=$PATH_NAME modes=${MODE_LIST[*]} variants=${VAR_LIST[*]}"
  echo "configurations_per_offered_load_block=$CONFIGS_PER_BLOCK"
  [ -z "$EXPECT_RING" ] || echo "expect_rx_ring=$EXPECT_RING"
  echo "rates_pps=${RATE_LIST[*]}"
  echo "uninstrumented_rates_pps=${UNINST_LIST[*]-none}"
  echo "blocks_per_rate=$REPS duration_s=$DUR warmup_s=$CELLWARMUP randomised=$RANDOMISE"
  echo "cells_instrumented=$INST_CELLS cells_uninstrumented=$UNINST_CELLS total=$TOTAL"
  echo "output=$RUN_DIR"
  # 43 s per cell is the median wall clock of a 30 s window plus install,
  # teardown and the two counter round-trips.
  echo "estimated_runtime_min=$(awk -v n="$TOTAL" -v d="$DUR" 'BEGIN{printf "%.0f", n*(d+13)/60}')"
  exit 0
fi

mkdir -p "$CELL_DIR"

ss -ltnH 2>/dev/null | grep -q ':4501' \
  || { echo "ERROR: TRex is not running; run scripts/trex_start.sh" >&2; exit 1; }
ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" \
  "for i in \$(seq 1 20); do [ \"\$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)\" = up ] && exit 0; sleep 1; done; exit 1" \
  || { echo "ERROR: DuT link $IFACE did not settle" >&2; exit 1; }

if [ -n "$EXPECT_RING" ]; then
  ACTUAL_RING=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" \
    "ethtool -g $IFACE 2>/dev/null | awk '/^Current hardware settings:/{f=1;next} f&&/^RX:/{print \$2;exit}'")
  [ "$ACTUAL_RING" = "$EXPECT_RING" ] \
    || { echo "ERROR: RX ring is '${ACTUAL_RING:-unknown}', expected $EXPECT_RING" >&2; exit 1; }
  echo "== rx ring verified: $ACTUAL_RING descriptors =="
fi

if [ "$SKIP_HC" = 0 ]; then
  echo "== health check: dut_audit =="
  ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" \
    "sudo bash -s -- $IFACE $CPU" < "$REPO/scripts/dut_audit.sh" \
    || { echo "ERROR: DuT isolation failed" >&2; exit 1; }
fi

"$REPO/scripts/manifest.sh" --iface "$IFACE" --cpu "$CPU" --host "$HOST" \
  > "$RUN_DIR/manifest.json" || { echo "ERROR: provenance manifest failed" >&2; exit 1; }

python3 - "$RUN_DIR/campaign.json" "$PATH_NAME" "$REPS" "$DUR" "$CELLWARMUP" \
  "$RANDOMISE" "$IFACE" "$CPU" "$HOST" "$PORT" "${EXPECT_RING:-0}" \
  "$(printf '%s,' "${MODE_LIST[@]}")" \
  "${VAR_LIST[0]}" "${VAR_LIST[1]}" \
  "$(printf '%s,' "${RATE_LIST[@]}")" \
  "$(printf '%s,' ${UNINST_LIST[@]+"${UNINST_LIST[@]}"})" <<'PY'
import datetime as dt, json, sys
(out, packet_path, reps, duration, warmup, randomise, iface, cpu, host, port,
 expect_ring, modes, var_a, var_b, rates, uninst) = sys.argv[1:]
split = lambda s: [int(x) for x in s.split(',') if x]
mode_list = [x for x in modes.split(',') if x]
variants = [var_a, var_b]
campaign = {
    'created_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
    'design': 'mode x variant configurations, randomised within offered-load block',
    'paper_step': 'four-configuration block and within-hook paired differences',
    'path': packet_path, 'modes': mode_list, 'variants': variants,
    'configurations': [
        {'mode': mode, 'variant': variant}
        for mode in mode_list for variant in variants
    ],
    'rx_ring_expected': int(expect_ring) or None,
    'rates_pps': split(rates), 'blocks_per_rate': int(reps),
    'uninstrumented_rates_pps': split(uninst),
    'duration_s': int(duration), 'warmup_s': int(warmup),
    'randomised_rate_order_per_block': bool(int(randomise)),
    'randomised_configuration_order_within_offered_load_block': bool(int(randomise)),
    'iface': iface, 'cpu': int(cpu), 'host': host, 'trex_port': int(port),
}
with open(out, 'w') as fh:
    json.dump(campaign, fh, indent=2)
    fh.write('\n')
PY

printf 'rate\tblock\torder\tmode\tvariant\tinstrumented\tvalid\taccepted_pps\tloss\tconservation\tcycles_per_pkt\tl2_fills_per_pkt\tccx_fills_per_pkt\tdram_fills_per_pkt\tinvalid_reasons\tfile\n' > "$SUMMARY"

echo "== four-configuration run: $PATH_NAME, modes=${MODE_LIST[*]}, variants=${VAR_LIST[*]} =="
echo "   rates=${RATE_LIST[*]}"
echo "   blocks=$REPS window=${DUR}s warmup=${CELLWARMUP}s randomised=$RANDOMISE"
[ "${#UNINST_LIST[@]}" -eq 0 ] || echo "   uninstrumented repetition at: ${UNINST_LIST[*]}"
echo "   output=$RUN_DIR"

cell=0
failures=0
invalid=0

# One pass of every mode/variant combination at one rate. Randomising all four
# configurations together is what makes both within-hook effects and their
# cross-hook difference within-block quantities.
run_pass() {
  local rate=$1 block=$2 inst=$3
  local pass_configs=() order=0 config mode v rc file
  for mode in "${MODE_LIST[@]}"; do
    for v in "${VAR_LIST[@]}"; do
      pass_configs+=("$mode $v")
    done
  done
  if [ "$RANDOMISE" = 1 ]; then
    mapfile -t pass_configs < <(printf '%s\n' "${pass_configs[@]}" | shuf)
  fi
  for config in "${pass_configs[@]}"; do
    read -r mode v <<<"$config"
    order=$((order + 1))
    cell=$((cell + 1))
    printf '[%d/%d] %.3f Mpps block=%d order=%d %s/%s%s ... ' \
      "$cell" "$TOTAL" "$(awk -v r="$rate" 'BEGIN{print r/1e6}')" \
      "$block" "$order" "$mode" "$v" "$([ "$inst" = 0 ] && echo ' (no counters)')"
    local args=(--path "$PATH_NAME" --mode "$mode" --touch "$v" --pps "$rate"
      --duration "$DUR" --warmup "$CELLWARMUP" --iface "$IFACE" --cpu "$CPU"
      --host "$HOST" --port "$PORT" --outdir "$CELL_DIR")
    [ "$inst" = 1 ] || args+=(--no-perf)
    local output
    output=$("$REPO/scripts/run_cell.sh" "${args[@]}" 2>&1)
    rc=$?
    file=$(printf '%s\n' "$output" | sed -n 's/^-- saved: //p' | tail -1)
    if [ "$rc" -ne 0 ] || [ -z "$file" ] || [ ! -f "$file" ]; then
      failures=$((failures + 1))
      echo "FAILED (rc=$rc)"
      printf '%s\n' "$output" | tail -3 >&2
      printf '%s\t%s\t%s\t%s\t%s\t%s\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tcell failed\t\n' \
        "$rate" "$block" "$order" "$mode" "$v" "$inst" >> "$SUMMARY"
      continue
    fi
    local row
    row=$(python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
reasons = '; '.join(d.get('invalid_reasons') or []) or '-'
print('\t'.join(str(x) for x in [
    d.get('valid', True), d['accepted_pps'], d['loss_fraction'],
    d['conservation_ratio'], d.get('cycles_per_pkt', 0),
    d.get('fills_lcl_l2_per_pkt', 0), d.get('fills_lcl_cache_per_pkt', 0),
    d.get('fills_lcl_dram_per_pkt', 0), reasons]))
PY
)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rate" "$block" "$order" "$mode" "$v" "$inst" "$row" "$file" >> "$SUMMARY"
    case "$row" in
      False*) invalid=$((invalid + 1))
              printf '%s\n' "$output" | sed -n '/INVALID CELL/,$p' | head -4 ;;
      *) printf '%s\n' "$output" | sed -n 's/^-- accepted/   accepted/p' ;;
    esac
  done
}

# A block is one complete pass over every rate. Running all repetitions of one
# rate back to back instead would put that rate's ten cells inside a few minutes,
# which hides the drift the campaign has to survive and confounds slow drift with
# the offered load. Block outside, rate inside, rate order shuffled per block.
for block in $(seq 1 "$REPS"); do
  block_rates=("${RATE_LIST[@]}")
  if [ "$RANDOMISE" = 1 ]; then
    mapfile -t block_rates < <(printf '%s\n' "${block_rates[@]}" | shuf)
  fi
  for rate in "${block_rates[@]}"; do
    run_pass "$rate" "$block" 1
    if is_uninst "$rate"; then
      run_pass "$rate" "$block" 0
    fi
  done
done

python3 "$REPO/scripts/analyse_paired.py" "$SUMMARY" "$ANALYSIS" \
  "${VAR_LIST[0]}" "${VAR_LIST[1]}"

echo "-- cells:    $CELL_DIR"
echo "-- written:  $SUMMARY, $ANALYSIS"
[ "$invalid" -eq 0 ] || echo "-- NOTE: $invalid of $TOTAL cells are marked invalid and are excluded" >&2
[ "$failures" -eq 0 ] || { echo "WARNING: $failures of $TOTAL cells failed outright" >&2; exit 1; }
