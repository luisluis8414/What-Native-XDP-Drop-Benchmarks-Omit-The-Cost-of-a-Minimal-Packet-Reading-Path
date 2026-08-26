#!/usr/bin/env bash
# pmc_probe.sh -- pin down what each PMCx043 unit mask counts on this processor.
#
# PMCx043 (Core::X86::Pmc::Core::LsRefillsFromSys, "Demand Data Cache Fills by
# Data Source") reports where an L1 data cache fill came from. Which bit means
# DRAM and which means cache decides whether a cost difference is a miss-count
# effect or a miss-latency effect, so the mapping has to be measured and not
# assumed.
#
# Runs ON the DuT as root. Uploaded through SSH like the other DuT helpers,
# because the DuT exposes no SCP subsystem.
#
#   ssh dut@... 'sudo bash -s -- --cpu 10' < scripts/pmc/pmc_probe.sh
#
# Options (defaults in []):
#   --cpu N [10]        isolated core to measure on
#   --repeats N [5]     perf stat -r value
#   --keep              leave the built binary in /tmp for a manual re-run
set -uo pipefail

CPU=10
REPS=5
KEEP=0
while [ $# -gt 0 ]; do case "$1" in
  --cpu) CPU=$2; shift 2 ;;
  --repeats) REPS=$2; shift 2 ;;
  --keep) KEEP=1; shift ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac; done

WORK=$(mktemp -d /tmp/pmc_probe.XXXXXX)
BIN="$WORK/chase"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

rule() { printf '\n%s\n' "================================================================"; }

# ---------------------------------------------------------------- step 0
rule; echo "STEP 0  processor and measurement environment"; rule
awk -F: '/^(vendor_id|cpu family|model|model name|stepping|microcode)/ {
  gsub(/^[ \t]+|[ \t]+$/,"",$1); gsub(/^[ \t]+/,"",$2); print "  " $1 ": " $2 }' \
  /proc/cpuinfo | sort -u
printf '  cache sizes:\n'
for i in /sys/devices/system/cpu/cpu"$CPU"/cache/index*; do
  [ -d "$i" ] || continue
  printf '    L%s %-6s %8s  shared with %s\n' \
    "$(cat "$i/level")" "$(cat "$i/type")" "$(cat "$i/size")" \
    "$(cat "$i/shared_cpu_list")"
done
printf '  perf version           : %s\n' "$(perf --version 2>/dev/null)"
printf '  perf_event_paranoid    : %s\n' "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)"
printf '  nmi_watchdog           : %s\n' "$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)"
printf '  smt control            : %s\n' "$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)"
printf '  governor cpu%-3s        : %s\n' "$CPU" \
  "$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_governor 2>/dev/null)"
printf '  boost                  : %s\n' "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"

# Family 17h has six core performance counters, PPR 54945 section 2.1.15.1
# ("The RDPMC[5:0] instruction accesses core events"). The NMI watchdog claims
# one of them while it is enabled, which silently forces multiplexing on a
# six-event group and would make every count in this report an extrapolation.
NMI=$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)
if [ "$NMI" != 0 ]; then
  echo
  echo "  WARNING the NMI watchdog holds one of the six core counters."
  echo "          Six-event groups below will multiplex. To free it:"
  echo "            sysctl -w kernel.nmi_watchdog=0"
  echo "          and afterwards restore it with kernel.nmi_watchdog=$NMI"
fi

# ---------------------------------------------------------------- step 1
rule; echo "STEP 1  does perf know the symbolic vendor events?"; rule
if perf list 2>/dev/null | grep -q -i -E 'refill|from_sys'; then
  perf list 2>/dev/null | grep -i -E 'refill|ls_refills|from_sys'
else
  echo "  (no symbolic match; the raw encodings below are then the only route)"
fi
echo
echo "  full unit-mask list as perf reports it:"
perf list 2>/dev/null | grep -i -A2 'ls_refills_from_sys' | sed 's/^/  /' | head -40

# ---------------------------------------------------------------- build
cat > "$WORK/chase.c" <<'CHASE'
/* Pointer chase over a randomly permuted cycle of cache lines. The next
   address is only known once the current load returns, so neither the stride
   prefetcher nor the region prefetcher can run ahead. Every step is therefore
   one demand fill from whatever level still holds the line.

   argv: <bytes> <iterations> [hugepages]
   iterations == 0 builds the chain and exits, which gives the setup-only
   baseline that has to be subtracted from the full run.
   hugepages == 1 asks for transparent huge pages, which removes almost every
   page walk. Comparing the two isolates the walk from the fill. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

int main(int argc, char **argv) {
    size_t bytes = (argc > 1) ? strtoull(argv[1], NULL, 0) : (256UL << 20);
    unsigned long iters = (argc > 2) ? strtoul(argv[2], NULL, 0) : 1;
    int huge = (argc > 3) ? atoi(argv[3]) : 0;
    const size_t LINE = 64;
    size_t n = bytes / LINE, i;
    if (n < 2) return 1;

    void **buf = NULL;
    if (posix_memalign((void **)&buf, 2UL << 20, n * LINE)) return 1;
    if (huge && madvise(buf, n * LINE, MADV_HUGEPAGE))
        fprintf(stderr, "    note: MADV_HUGEPAGE refused\n");
    memset(buf, 0, n * LINE);

    size_t *idx = malloc(n * sizeof(size_t));
    if (!idx) return 1;
    for (i = 0; i < n; i++) idx[i] = i;
    unsigned long s = 88172645463325252UL;      /* fixed seed: same chain every run */
    for (i = n - 1; i > 0; i--) {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        size_t j = s % (i + 1), t = idx[i]; idx[i] = idx[j]; idx[j] = t;
    }
    for (i = 0; i < n; i++)
        *(void **)((char *)buf + idx[i] * LINE) =
            (char *)buf + idx[(i + 1) % n] * LINE;
    free(idx);

    void *p = buf;
    unsigned long steps = 0;
    for (unsigned long it = 0; it < iters; it++)
        for (i = 0; i < n; i++) { p = *(void **)p; steps++; }

    fprintf(stderr, "    chase %zu B, %zu lines, %lu steps, hugepages %d, sink %p\n",
            bytes, n, steps, huge, p);
    free(buf);
    return 0;
}
CHASE
command -v gcc >/dev/null || { echo "ERROR: no gcc on the DuT, cannot build the probe" >&2; exit 1; }
gcc -O2 -o "$BIN" "$WORK/chase.c" || { echo "ERROR: build failed" >&2; exit 1; }

# The five defined bits of PMCx043 plus the union AMD leaves for all of them.
# Raw form rUUEE: UU is the unit mask in PERF_CTL[15:8], EE the event select.
M_L2=r0143       # bit 0  MABRESP_LCL_L2
M_LCLC=r0243     # bit 1  LS_MABRESP_LCL_CACHE
M_LDRAM=r0843    # bit 3  LS_MABRESP_LCL_DRAM
M_RCACHE=r1043   # bit 4  LS_MABRESP_RMT_CACHE
M_RDRAM=r4043    # bit 6  LS_MABRESP_RMT_DRAM
M_ALL=r5b43      # 0x5b = 0x01|0x02|0x08|0x10|0x40
FIVE="$M_L2,$M_LCLC,$M_LDRAM,$M_RCACHE,$M_RDRAM"

run() {  # run <label> <events> <args...>
  local label=$1 events=$2; shift 2
  echo
  echo "  --- $label"
  echo "      events: $events"
  perf stat -r "$REPS" -C "$CPU" -e "$events" -- taskset -c "$CPU" "$BIN" "$@" 2>&1 \
    | sed 's/^/      /'
}

# ---------------------------------------------------------------- step 3
rule; echo "STEP 3  microbenchmarks, all five masks in one group"; rule
echo "  Working sets against this core: L2 512 KiB, L3 8 MiB per CCX."
echo "  Each case is run twice. iterations=0 is chain setup only, so the"
echo "  difference between the two is the chase and nothing else."

echo
echo "  CASE DRAM  256 MiB, far beyond the 8 MiB L3"
run "chase" "$FIVE,cycles" $((256*1024*1024)) 3
run "setup only" "$FIVE,cycles" $((256*1024*1024)) 0

echo
echo "  CASE DRAM WITH HUGE PAGES  same 256 MiB, page walks largely removed"
echo "  A DRAM fill count that survives this is a fill. One that collapses was"
echo "  page-walk traffic counted as a demand fill."
run "chase, THP" "$FIVE,cycles" $((256*1024*1024)) 3 1
run "setup only, THP" "$FIVE,cycles" $((256*1024*1024)) 0 1

echo
echo "  CASE CCX CACHE  4 MiB, beyond the 512 KiB L2, inside the 8 MiB L3"
run "chase" "$FIVE,cycles" $((4*1024*1024)) 1500
run "setup only" "$FIVE,cycles" $((4*1024*1024)) 0

echo
echo "  CASE LOCAL L2  256 KiB, inside the 512 KiB L2"
run "chase" "$FIVE,cycles" $((256*1024)) 50000
run "setup only" "$FIVE,cycles" $((256*1024)) 0

# ---------------------------------------------------------------- step 4
rule; echo "STEP 4  additivity, five masks against the 0x5b union"; rule
echo "  Six events in one group, so the comparison is within a single run and"
echo "  not across two. Any shortfall is either a source outside the five"
echo "  defined bits or a counter that did not run the whole time."
run "DRAM, five plus union" "$FIVE,$M_ALL" $((256*1024*1024)) 3
run "L2, five plus union"   "$FIVE,$M_ALL" $((256*1024)) 50000

# ---------------------------------------------------------------- step 5
rule; echo "STEP 5  multiplexing check for the intended measurement"; rule
echo "  Field 5 of the CSV is the fraction of the window the event was"
echo "  scheduled. Anything below 100.00 means the number is extrapolated."
csv() {
  local label=$1 events=$2; shift 2
  echo
  echo "  --- $label"
  perf stat -x, -C "$CPU" -e "$events" -- taskset -c "$CPU" "$BIN" "$@" 2>&1 \
    | awk -F, 'NF>=5 && $3!="" {printf "      %-28s %18s  run %s%%\n", $3, $1, $5}'
}
csv "3 events: cycles, instructions, LCL_DRAM" \
    "cycles,instructions,$M_LDRAM" $((256*1024*1024)) 1
csv "5 events: plus LCL_L2 and LCL_CACHE" \
    "cycles,instructions,$M_LDRAM,$M_L2,$M_LCLC" $((256*1024*1024)) 1
csv "6 events: plus stalled-cycles-backend" \
    "cycles,instructions,$M_LDRAM,$M_L2,$M_LCLC,stalled-cycles-backend" \
    $((256*1024*1024)) 1
csv "7 events: the run_cell.sh set plus three masks" \
    "cycles,instructions,cache-misses,branch-misses,$M_LDRAM,$M_L2,$M_LCLC" \
    $((256*1024*1024)) 1

# ---------------------------------------------------------------- step 6
rule; echo "STEP 6  does the symbolic name carry the raw encoding?"; rule
echo "  Symbolic and raw in the same group. Equal counts confirm the mapping"
echo "  that perf ships; unequal counts mean the JSON and the PPR disagree."
for sym in ls_refills_from_sys.ls_mabresp_lcl_dram \
           ls_refills_from_sys.ls_mabresp_lcl_l2 \
           ls_refills_from_sys.ls_mabresp_lcl_cache; do
  if perf list 2>/dev/null | grep -q "$sym"; then
    case "$sym" in
      *lcl_dram)  raw=$M_LDRAM ;;
      *lcl_l2)    raw=$M_L2 ;;
      *lcl_cache) raw=$M_LCLC ;;
    esac
    run "$sym vs $raw" "$sym,$raw" $((256*1024*1024)) 1
  else
    echo "  (perf does not know $sym, nothing to cross-check)"
  fi
done

rule; echo "probe complete"; rule
