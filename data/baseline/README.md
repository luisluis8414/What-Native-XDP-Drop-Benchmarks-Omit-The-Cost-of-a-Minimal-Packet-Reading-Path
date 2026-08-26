# Native XDP line-rate baseline

This directory contains a preliminary line-rate measurement of native XDP
`no-touch`. The measurement asks whether the cheapest tested receive path is
CPU-limited at the 10 GbE line rate.

The baseline used an RX ring with 4096 descriptors. The current paper reports
its main results from the later 512-descriptor paired campaign. Do not use this
baseline as the source for the paper's saturation onsets or processed-rate
curves.

## Measurement design

The directory `xdp_drop_linerate_20260823T121922Z/` contains five repetitions
of one configuration:

| Setting | Value |
|---|---|
| XDP hook | Native |
| `xdp-bench` operation | `no-touch` |
| Requested rate | 14,880,952 packets per second |
| RX ring | 4096 descriptors |
| Warm-up | 5 seconds |
| Measured window | 30 seconds |
| Repetitions | 5 |
| Measurement CPU | CPU 10 |

## What the data show

All five repetitions passed the implemented validity checks. Their median
processed rate was 13.8724 Mpps. Individual rates ranged from 13.8395 to
13.8952 Mpps, which gives a 0.402 percent range around the median.

The median pre-XDP loss was 6.329 percent at the requested line rate. The
measurement core was active for 100.00 percent of the window. These two values
show that this 4096-descriptor configuration was processing-limited at line
rate.

The median cost was 230.2 active core cycles per processed packet. Individual
values ranged from 229.8 to 230.7 cycles per packet. The program's own median
drop rate was 13.8743 Mpps, which closely matched the DUT receive counter.

This dataset contains only one offered load. It cannot establish a saturation
onset or a load-dependent processing curve. The paper derives both from the
32-load, 512-descriptor paired campaign.

## Files

| File | Content |
|---|---|
| `campaign.json` | Frozen purpose, rate, timing, and testbed arguments |
| `manifest.json` | Exact hardware, software, firmware, and DUT configuration |
| `cells/*.json` | Raw counters, derived metrics, and validity verdicts |
| `cells/*.state` | DUT state before and after each measured window |
| `summary.tsv` | One derived row per repetition |
| `analysis.txt` | Human-readable summary of the five repetitions |

The cell JSON files and state sidecars are authoritative. `summary.tsv` and
`analysis.txt` are derived files.
