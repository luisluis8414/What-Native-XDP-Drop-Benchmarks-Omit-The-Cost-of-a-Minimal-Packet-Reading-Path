# PMCx043 unit masks on the DuT: measured mapping

Target: AMD Ryzen 5 1600 in the DuT, `dut@192.168.137.50`, measurement core CPU 10.
Raw probe log: `data/artifacts/pmc_probe_20260823T104015Z.txt`.
Probe: `scripts/pmc/pmc_probe.sh`, run 2026-08-23, `perf stat -r 5`, isolated core, NMI
watchdog already at 0, SMT off, governor performance, boost off.

## Result table

Verified means the microbenchmark reproduced the PPR description on this
processor. Where it does not, the row says so.

| Mask | Bit | PPR mnemonic | Data source | Empirical evidence | Status |
|---|---|---|---|---|---|
| 0x01 | 0 | `MABRESP_LCL_L2` | local L2 hit | 256 KiB chase: 0.9998 fills/step, 99.98 % of all fills, 17.1 cycles/step | verified |
| 0x02 | 1 | `LS_MABRESP_LCL_CACHE` | cache in the local CCX other than the local L2, i.e. the shared L3 here | 4 MiB chase: 0.9396 fills/step, 93.96 % of all fills, 46.2 cycles/step | verified |
| 0x08 | 3 | `LS_MABRESP_LCL_DRAM` | DRAM or IO on this thread's die | 256 MiB chase: 0.9765 fills/step, 98.66 % of all fills, 319.0 cycles/step with huge pages | verified |
| 0x10 | 4 | `LS_MABRESP_RMT_CACHE` | cache hit in a remote CCX with home node on another die | reads exactly 0 in all 10 runs of all 4 cases | NOT verified, inert on this part |
| 0x40 | 6 | `LS_MABRESP_RMT_DRAM` | DRAM or IO on another die | reads exactly 0 in all 10 runs of all 4 cases | NOT verified, inert on this part |

Bits 2, 5 and 7 are reserved. 0x01 | 0x02 | 0x08 | 0x10 | 0x40 = 0x5B, so the
five defined bits are exactly the union mask.

## Primary source

PPR for AMD Family 17h Models 01h,08h, Revision B2, order 54945, Rev 3.03,
14 June 2019, section 2.1.15.4.2 (LS Events), page 165. Event
`PMCx043 [Data Cache Refills from System]`,
`Core::X86::Pmc::Core::LsRefillsFromSys`, "Demand Data Cache Fills by Data
Source". The six-counter budget is from section 2.1.15.1, which states that
RDPMC[5:0] reaches the core events.

## Step by step

### Step 1: perf does not ship the symbolic events

`perf list` on the DuT returns no match for `refill`, `ls_refills` or
`from_sys`. perf version 7.0.0 here carries no amdzen1 event JSON. Step 6 of
the probe therefore had nothing to cross-check, and the whole mapping rests on
the raw encodings. That is not a weakness: the raw encoding is what the PPR
defines, and the symbolic name would only be a second-hand label on top of it.

Raw form used throughout: `rUUEE`, unit mask in PERF_CTL[15:8], event select in
PERF_CTL[7:0]. So `r0843` is umask 0x08 on event 0x43.

### Step 3: microbenchmarks

Randomly permuted pointer chase, one dependent load per step, so no prefetcher
can run ahead. Each case was measured twice, once with the chase and once with
chain setup only, and the setup was subtracted. All figures are per chase step,
means of 5 runs.

| Case | working set | 0x01 | 0x02 | 0x08 | 0x10 | 0x40 | cycles/step |
|---|---|---|---|---|---|---|---|
| local L2 | 256 KiB | **0.9998** | 0.0002 | 0.0000 | 0 | 0 | 17.1 |
| CCX cache | 4 MiB | 0.0604 | **0.9396** | 0.0000 | 0 | 0 | 46.2 |
| DRAM, 4 KiB pages | 256 MiB | -0.0004 | 0.0137 | **0.9765** | 0 | 0 | 378.3 |
| DRAM, huge pages | 256 MiB | 0.0001 | 0.0153 | **0.9839** | 0 | 0 | 319.0 |

Every case is dominated by exactly one mask, and it is a different mask in each
case. The 6.04 % of L2 fills in the 4 MiB case is the share of the working set
that still fits the 512 KiB L2. The 1.4 % of 0x02 in the DRAM case is the share
of lines that happen to survive in L3.

The cycles per step are an independent corroboration that does not use the fill
counters at all. 17.1, 46.2 and 319.0 cycles are the L2, L3 and DRAM access
latencies of this processor. The case that lights up 0x01 runs at L2 latency,
the case that lights up 0x02 at L3 latency, the case that lights up 0x08 at DRAM
latency. Two independent signals agree on the same assignment.

### Step 3b: page-walk control (added to the original plan)

A 256 MiB random chase over 4 KiB pages spans 65536 pages and misses the TLB on
almost every step. If page-walk memory traffic were counted as a demand data
fill, the DRAM case would be inflated by an unknown amount. Repeating it with
`MADV_HUGEPAGE` settles it:

- DRAM fills 12,287,104 to 12,380,936, a change of +0.76 %
- cycles per step 378.3 to 319.0, a change of -59.2 cycles

The fill count does not move, so PMCx043 bit 3 counts demand data fills and not
table-walk traffic. The cycle count moves a lot, so on this processor a random
DRAM read beyond TLB reach carries about 59 extra cycles of page walk, roughly
18.6 ns at 3.19 GHz. That number is a by-product of the control and is worth
recording separately.

### Step 4: additivity

Five masks plus the 0x5B union in one six-event group, so the comparison is
within a single run.

| Case | sum of the five | 0x5B union | deviation |
|---|---|---|---|
| DRAM 256 MiB | 21,642,510 | 21,642,506 | +4, or +0.0000185 % |
| L2 256 KiB | 204,820,317 | 204,820,319 | -2, or -0.0000010 % |

The masks are additive to within a handful of counts out of hundreds of
millions, and the residual is the size of the rounding on a 5-run mean. The five
bits therefore exhaust the sources: no demand data fill on this machine comes
from anywhere outside them.

### Step 5: multiplexing

| event set | events | run share |
|---|---|---|
| cycles, instructions, 0x08 | 3 | 100.00 % |
| plus 0x01 and 0x02 | 5 | 100.00 % |
| plus stalled-cycles-backend | 6 | 100.00 % |
| the current run_cell.sh set plus three masks | 7 | **85.00 %** |

Six programmable core counters, exactly as the PPR states, and the NMI watchdog
was already off so all six were available. Seven events multiplex.

The current `run_cell.sh` perf line is
`cycles,instructions,cache-misses,branch-misses` plus three `msr/` events. The
MSR events sit on a different PMU and consume no counter, so the core budget in
use is four. Two masks can be added without dropping anything. Three cannot.

## Contradictions and open points, stated rather than resolved

**The document does not cover this stepping.** `/proc/cpuinfo` reports family
23, model 1, stepping 1, which is Family 17h Model 01h revision B1. The PPR
consulted, Rev 3.03, is for Models 01h,08h revision **B2**. No B1 document was
consulted. The measurements agree with the B2 definitions at every point that
could be tested, which is evidence that the definitions carry over, but the
documentary gap is not closed.

**0x10 and 0x40 are unverified and cannot be verified here.** They read exactly
zero in every run of every case. That is consistent with the PPR, because the
Ryzen 5 1600 is a single-die part and the condition both masks describe, a home
node on a different die, cannot occur. But a mask that never fires has not been
shown to mean what the document says it means. No microbenchmark on this machine
can close this. It would need a multi-die part.

**Cross-CCX traffic was not isolated.** The PPR puts a hit in a remote CCX with
the home node on this die into 0x02, together with the local CCX cache. The
4 MiB case cannot separate the two, since it never leaves the local CCX. On this
DuT the distinction does not matter, because the measurement core is pinned and
its CCX is CPUs 6, 8 and 10 sharing the 8 MiB L3. It would matter for any
measurement that lets work migrate across CCX.

**A defect in the probe script.** The CSV parser in step 5 folds the
benchmark's own stderr line into the result table, producing one nonsense row
per configuration. It does not touch any counter value. Cosmetic, worth fixing
before the script is used again.

## Recommendation

Use **0x08, 0x02 and 0x01**, in that order of importance. On this part they are
the only three masks that can fire, they are additive, and together they
decompose every demand data fill by source.

For the intended measurement the recommended perf set is

```
cycles,instructions,r0843,r0143,r0243
```

which the probe confirmed at 100 % run share, with one counter still free for
`branch-misses`, `stalled-cycles-backend`, or `PMCx046` (Total Page Table Walks,
`r0046`) if the page-walk question is being pursued.

This set should **replace** `cache-misses` rather than be added alongside it.
Seven events multiplex at 85 %, and the generic `cache-misses` event is the
weaker of the two: it names no cache level on this processor, which the paper
already records as a limitation. The three masks name the level explicitly and
are strictly more informative.

If `cache-misses` and `branch-misses` must both stay for continuity with data
already collected, then only two masks fit, and they should be 0x08 and 0x02.
That pair still separates a DRAM fill from a cache fill, which is the
distinction the analysis turns on.
