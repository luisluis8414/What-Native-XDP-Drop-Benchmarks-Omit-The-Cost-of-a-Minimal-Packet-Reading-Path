# Supporting artifacts

This directory contains supporting evidence that is not represented by one
measurement cell. It records the primary campaign console log, the PMU event
mapping, and the loaded code for both `xdp-bench` operations.

## Contents

| Path | Purpose |
|---|---|
| `campaign_4config_ring512_20260823T143103Z.log` | Console log of the primary campaign |
| `pmc043_mask_mapping_20260823.md` | Interpretation of the Zen 1 fill-source masks |
| `pmc_probe_20260823T104015Z.txt` | Raw output from the PMU microbenchmark |
| `xdp_bench_disassembly_20260821/` | eBPF and x86-64 code for both operations |

## Primary campaign log

`campaign_4config_ring512_20260823T143103Z.log` records the complete console
output from the 512-descriptor campaign. It begins with the DUT readiness audit
and the frozen campaign settings.

The log records 32 offered loads and ten blocks per load. The campaign contains
1,280 instrumented cells and 80 counter-free control cells. Each progress line
reports configuration, accepted rate, loss, conservation, CPU activity, cost,
and generator errors.

The log ends with the generated paired analysis. It is an execution audit
trail, not the primary measurement source. The raw cells, campaign manifest,
summary, and analysis are under
`data/paired/paired_4config_ring512_20260823/`.

## PMU event mapping

The PMU probe maps AMD event `PMCx043`, Demand Data Cache Fills by Data Source,
on the Ryzen 5 1600 DUT. A dependent pointer chase isolates working sets served
by local L2, local cache complex, and local DRAM.

The measured mapping is:

| Raw event | Unit mask | Measured source | Main probe result |
|---|---:|---|---|
| `r0143` | `0x01` | Local L2 | 0.9998 fills per L2 chase step |
| `r0243` | `0x02` | Local cache complex | 0.9396 fills per cache chase step |
| `r0843` | `0x08` | Local DRAM | 0.9839 fills per huge-page DRAM step |

The local L2, cache, and DRAM cases ran at 17.1, 46.2, and 319.0 cycles per
step. These independent latency levels support the same source assignment.

The five defined masks were additive to within four counts across more than 21
million DRAM-case events. Masks `0x10` and `0x40` remained zero in every probe
run because the single-die DUT cannot exercise their remote-die conditions.
Their documented meanings were therefore not verified on this processor.

The probe also confirmed the six-counter core PMU budget. Six events received
100 percent run time, while seven events received 85 percent. The final
measurement set therefore uses exactly six core events and rejects
multiplexing.

`pmc043_mask_mapping_20260823.md` contains the interpretation and limitations.
`pmc_probe_20260823T104015Z.txt` contains the raw `perf` output. The probe note
mentions an older `run_cell.sh` event set. The final script uses `cycles`,
`instructions`, `branch-misses`, `r0143`, `r0243`, and `r0843`.

## Loaded XDP programs

The directory `xdp_bench_disassembly_20260821/` records the translated eBPF and
native JIT code loaded on the DUT. Both programs came from Ubuntu package
`xdp-tools` version `1.6.2-1ubuntu1`.

| Operation | eBPF slots | eBPF bytes | x86-64 instructions | JIT bytes |
|---|---:|---:|---:|---:|
| `no-touch` | 38 | 304 | 48 | 180 |
| `read-data` | 51 | 408 | 68 | 238 |
| Added by `read-data` | 13 | 104 | 20 | 58 |

The difference is a complete code path. It includes the verifier-required
Ethernet-header bounds check, its branch, and the packet-data load. The measured
cost must not be interpreted as the latency of one load instruction.

The files have these roles:

| File | Content |
|---|---|
| `README.md` | Capture method, versions, hashes, and instruction counts |
| `no-touch.txt` | Metadata and complete eBPF and x86-64 disassembly |
| `read-data.txt` | Metadata and complete eBPF and x86-64 disassembly |
| `dump_bpf_jit.c` | Helper used to extract the JIT image |
