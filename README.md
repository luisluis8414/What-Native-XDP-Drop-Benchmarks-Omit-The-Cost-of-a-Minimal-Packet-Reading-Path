# Artifact for "What Native XDP Drop Benchmarks Omit"

This repository contains the measurement scripts and data for the paper
"What Native XDP Drop Benchmarks Omit: The Cost of a Minimal Packet-Reading
Path." The study measures a single-core XDP receive path on a direct 10 GbE
link.

The experiment compares two operations from `xdp-bench`:

- `no-touch` returns `XDP_DROP` without reading packet data.
- `read-data` checks the Ethernet header bounds and reads the EtherType field
  before returning the same verdict.

Both operations run at the native XDP hook and the generic `skb` hook. The
measurement records processed throughput, packet loss, active core cycles, and
data-cache fills. This repository does not contain the paper source.

## Repository layout

```text
.
├── README.md
├── scripts/
│   ├── trex/                  # TRex profile and interface configuration
│   ├── run_cell.sh            # One measurement cell
│   ├── run_paired.sh          # Four-configuration block campaign
│   ├── analyse_paired.py      # Campaign analysis
│   ├── dut_prepare.sh         # DUT configuration
│   ├── dut_audit.sh           # DUT pre-run checks
│   └── ...                    # Validation and supporting scripts
└── data/
    ├── paired/                # Four-configuration campaign
    ├── baseline/              # Native XDP line-rate baseline
    ├── validation/            # Generator and CPU-isolation checks
    └── artifacts/             # JIT disassembly and PMU event mapping
```

## Main campaigns

The `data/paired/` directory contains the four-configuration campaign. It
crosses the two operations with the two XDP hooks. Every offered-load block
contains all four configurations in randomized order.

| Directory | RX ring | Loads | Blocks per load | Measured window |
|---|---:|---:|---:|---:|
| `paired_4config_ring512_20260823` | 512 descriptors | 32 | 10 | 30 seconds |

Each cell also has a 5-second warm-up. The campaign uses the driver's default
ring size of 512 descriptors.

## Campaign files

Each campaign directory contains the files needed to trace an aggregate back
to the recorded measurements:

- `campaign.json` records the design, offered loads, timing, repetitions, and
  requested testbed settings.
- `manifest.json` records the DUT and generator hardware, software versions,
  firmware, kernel settings, and active configuration.
- `cells/*.json` contains one raw measurement record per cell.
- `cells/*.state` contains the associated DUT state checks.
- `summary.tsv` collects the fields used by the analysis.
- `analysis.txt` contains the generated human-readable report.

The `file` column in each `summary.tsv` preserves the absolute path used during
data collection. These paths document provenance and are not portable. The
corresponding raw files are available in the adjacent `cells/` directory.

## Reproduce the stored analysis

The paired analysis needs only Python 3 and the stored `summary.tsv`. Run this
command from the repository root:

```bash
python3 scripts/analyse_paired.py \
  data/paired/paired_4config_ring512_20260823/summary.tsv \
  /tmp/ring512-analysis.txt \
  no-touch read-data
```

Compare the regenerated report with the archived report:

```bash
cmp /tmp/ring512-analysis.txt \
  data/paired/paired_4config_ring512_20260823/analysis.txt
```

A successful `cmp` produces no output.

## Run a new measurement

New measurements require two Linux hosts connected by a dedicated 10 GbE
link. The tester runs TRex and the orchestration scripts. The device under test
(DUT) runs the XDP programs and exposes an SSH account with non-interactive
`sudo` access.

The archived manifests describe the exact reference environment. The scripts
assume TRex 3.08 under `/opt/trex/v3.08` by default. They also use standard
Linux networking tools, `xdp-tools`, `perf`, `mpstat`, and Python 3. The optional
CPU-activity validation additionally requires `bpftrace`.

Review `scripts/trex/trex_cfg.yaml` before starting TRex. The PCI addresses in
that file are specific to the original tester.

Start TRex on the tester:

```bash
scripts/trex_start.sh
```

Prepare and audit the DUT. The following commands use the original interface,
measurement CPU, and 512-descriptor RX ring:

```bash
ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1 10 512' \
  < scripts/dut_prepare.sh
ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1 10' \
  < scripts/dut_audit.sh
```

The audit must end with `ALL OK`. A short plan verifies campaign arguments
without starting measurements:

```bash
scripts/run_paired.sh \
  --rates 1m,2m,14m,14880952 \
  --expect-rx-ring 512 \
  --reps 1 \
  --plan
```

Remove `--plan` only after checking the testbed and output path. For an exact
rerun, use the loads and settings recorded in the selected `campaign.json`.
Each new campaign writes its raw cells, manifest, summary, and analysis below
`data/paired/`.

## Measurement integrity

`run_cell.sh` accepts a cell only when its state and counter checks pass. It
records invalidity reasons instead of silently dropping failed checks. The
analysis uses only valid instrumented cells and reports block completeness
before calculating paired differences.

At 14.0 Mpps and at line rate the campaign repeats every block once with the
performance counters disabled. `campaign.json` lists these two loads under
`uninstrumented_rates_pps`, and the `instrumented` column in `summary.tsv`
marks the 80 cells they produce. These cells bound the effect of the counters
on throughput and are reported in the `INSTRUMENTATION CHECK` section of
`analysis.txt`. They do not enter any per-packet value or paired difference.

The manifests and raw cell records are the authoritative sources for hardware,
software, configuration, and measured values. The generated summaries and
reports are derived data.
