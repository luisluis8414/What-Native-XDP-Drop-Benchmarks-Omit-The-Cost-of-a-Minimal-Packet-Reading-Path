# Measurement scripts

These scripts implement the measurements for "What Native XDP Drop Benchmarks
Omit: The Cost of a Minimal Packet-Reading Path." Run all commands in this file
from the repository root.

The paper compares two `xdp-bench` operations at two XDP hooks:

| Hook | Operation | Meaning |
|---|---|---|
| `native` | `no-touch` | Drop without reading packet data |
| `native` | `read-data` | Check the Ethernet header and read EtherType |
| `skb` | `no-touch` | Run the same drop operation at generic XDP |
| `skb` | `read-data` | Run the same read operation at generic XDP |

The primary campaign uses an RX ring with 512 descriptors. It measures 32
offered loads, ten blocks per load, a 5-second warm-up, and a 30-second
measurement window. Each block contains all four configurations in randomized
order. The load order is also randomized within each repetition.

The paper reports the 512-descriptor campaign. The archived 4096-descriptor
campaign is an additional ring-size sensitivity measurement. The paper uses it
only as a secondary limitation and sensitivity check.

## Safety and roles

The scripts use two Linux hosts:

- The **tester** runs TRex, generates traffic, and starts each campaign.
- The **device under test** (DUT) runs the XDP programs and exposes SSH access.

Several commands change system state. `trex_start.sh` binds both tester NIC
functions to `vfio-pci`. `dut_prepare.sh` changes queues, offloads, flow
control, CPU frequency settings, SMT, idle states, and IRQ placement. Review
the scripts and replace all testbed-specific addresses before running them.

Use only a dedicated testbed. Do not run these commands through a management
interface that shares either measured NIC.

## Reference testbed

The archived manifests provide the authoritative hardware and software record.
The paper summarizes the primary setup as follows:

| Component | Reference configuration |
|---|---|
| DUT CPU | AMD Ryzen 5 1600, one 3.2 GHz core |
| DUT NIC | Intel X520 with an 82599ES controller and `ixgbe` |
| DUT software | Ubuntu 26.04, Linux 7.0, `xdp-tools` 1.6.2 |
| Receive path | One queue, XDP JIT enabled, 512 RX descriptors |
| Generator | TRex 3.08 with DPDK and an Intel X520 |
| Traffic | One constant-rate UDP flow with 64-byte Ethernet frames |
| Link | Direct 10 GbE connection between tester and DUT |

The tester scripts expect TRex under `/opt/trex/v3.08`. The DUT scripts expect
non-interactive SSH and `sudo` access. `dut_audit.sh` reports missing DUT tools
before a campaign starts.

The measurement uses all six programmable core counters on the Zen 1 DUT.
Disable the NMI watchdog before measuring. `run_cell.sh` rejects a cell when
`perf` multiplexes any event.

## Values that must be adapted

The checked-in defaults reproduce the original testbed. Review these files and
arguments before using different hardware:

- `scripts/trex/trex_cfg.yaml` contains tester PCI addresses and the DUT MAC.
- `scripts/trex/smoke_stream.py` contains tester and DUT MAC addresses.
- Most commands default to DUT host `dut@192.168.137.50`.
- Most commands default to DUT interface `enp35s0f1` and CPU 10.
- Traffic uses TRex port 1 by default.
- `dut_audit.sh` expects CPUs 10 and 11 to be isolated at boot.
- `final_dut_audit.sh` contains exact kernel, PCI, and CPU expectations from the
  original DUT.

Persistent boot isolation is outside `dut_prepare.sh`. Configure it before the
campaign, then reboot the DUT. The audit expects `isolcpus` and `nohz_full` to
report CPUs 10 and 11.

## Paper workflow

### 1. Start TRex

Run this command on the tester:

```bash
scripts/trex_start.sh
```

The script starts TRex in stateless mode and waits for its RPC port. Set
`TREX_DIR`, `CFG`, or `LOG` to override its three path defaults.

### 2. Prepare the DUT

The primary campaign uses a 512-descriptor RX ring:

```bash
ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1 10 512' \
  < scripts/dut_prepare.sh
```

The preparation script configures one combined queue. It disables receive
offloads, software steering, flow control, boost, SMT, and deep idle states. It
also selects the performance governor and pins the queue IRQ.

Native XDP attachment resets parts of the `ixgbe` configuration. `run_cell.sh`
therefore disables flow control and repins the IRQ after every attachment.

### 3. Run the readiness checks

The general audit is read-only:

```bash
ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1 10' \
  < scripts/dut_audit.sh
```

The last line must be `ALL OK`. Warnings about the queue IRQ are acceptable
before a cell because `run_cell.sh` repins and verifies the IRQ after each XDP
attachment.

The strict final audit reproduces the original DUT checks. It also attaches a
native program, checks the resulting runtime state, and cleans up afterward:

```bash
ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1 10 512' \
  < scripts/final_dut_audit.sh
```

This strict audit is intentionally hardware-specific. Adapt its expected values
before using another DUT.

### 4. Validate the generator

The generator validation checks 14, 14.5, and 14.880952 Mpps. The archived run
uses five repetitions with a 30-second traffic interval:

```bash
scripts/validate_generator.sh --duration 30 --reps 5 --plan
scripts/validate_generator.sh --duration 30 --reps 5
```

The script derives the transmitted rate from the TRex packet counter. DUT NIC
counters provide an independent cross-check. Results are written below
`data/validation/`.

### 5. Validate CPU isolation

The CPU-activity check uses `bpftrace` during one representative cell. It is a
one-time validation and is not part of every campaign cell:

```bash
scripts/run_cell.sh \
  --path xdp_drop \
  --mode native \
  --touch no-touch \
  --pps 14200000 \
  --duration 30 \
  --warmup 5 \
  --validate-cpu-activity \
  --outdir data/validation/cpu10
```

The resulting JSON contains a `cpu_activity` object. Its `clean` field must be
`true` for the validation to pass.

### 6. Measure the line-rate baseline

The baseline checks the cheapest configuration at the 64-byte line rate. The
archived run uses five repetitions:

```bash
scripts/measure_baseline_linerate.sh --reps 5 --plan
scripts/measure_baseline_linerate.sh --reps 5
```

This check does not replace the offered-load sweep. One line-rate point cannot
establish the saturation onset or the load-dependent processed rate.

### 7. Plan the primary campaign

The paper uses this 32-point load grid:

```bash
rates=0.25m,0.5m,0.75m,1m,1.5m,2m,2.5m,3m,3.5m,4m,4.5m,5m,5.5m,6m,6.5m,7m,7.5m,8m,8.5m,9m,9.5m,10m,10.5m,11m,11.5m,12m,12.5m,13m,13.5m,14m,14.5m,14880952

scripts/run_paired.sh \
  --rates "$rates" \
  --uninstrumented-rates 14m,14880952 \
  --expect-rx-ring 512 \
  --reps 10 \
  --duration 30 \
  --cell-warmup 5 \
  --plan
```

`--plan` validates the grid and prints the expected cell count without changing
the testbed. The two uninstrumented rates add counter-free control blocks. The
paper's main metrics use the instrumented cells.

### 8. Run the primary campaign

Remove only `--plan` from the checked command:

```bash
scripts/run_paired.sh \
  --rates "$rates" \
  --uninstrumented-rates 14m,14880952 \
  --expect-rx-ring 512 \
  --reps 10 \
  --duration 30 \
  --cell-warmup 5
```

Keep the shell that defines `rates` open between the plan and the run. The
script creates a timestamped directory below `data/paired/` unless `--label` or
`--outdir` overrides it.

### 9. Regenerate the paired analysis

`run_paired.sh` creates `summary.tsv` and `analysis.txt` automatically. The
stored report can also be regenerated without access to the testbed:

```bash
python3 scripts/analyse_paired.py \
  data/paired/paired_4config_ring512_20260823/summary.tsv \
  /tmp/ring512-analysis.txt \
  no-touch read-data

cmp /tmp/ring512-analysis.txt \
  data/paired/paired_4config_ring512_20260823/analysis.txt
```

`analyse_paired.py` reports completeness, per-load medians, within-hook paired
differences, signs, range overlap, and cross-hook differences. It uses only
valid instrumented cells. The `top-load processed rate (diagnostic)` line is a
summary of the highest offered-load point. The paper instead reports the full
load-dependent curve and the saturation onset.

### 10. Generate paper figure tables

`make_results_figure.py` creates the `pgfplots` data tables used by the paper:

```bash
python3 scripts/make_results_figure.py \
  data/paired/paired_4config_ring512_20260823/summary.tsv \
  thr4_ring512
```

The script writes to `paper/figures/`. That directory belongs to the full paper
working tree and is not included in this data-only artifact repository. The
console line labelled `top-load processed rate` is diagnostic. The paper uses
the complete per-load tables written by the script.

### 11. Run the ring-size sensitivity campaign

Prepare the DUT with 4096 RX descriptors and rerun the same grid:

Set `rates` to the 32-point value from Step 7 if this is a new shell.

```bash
ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1 10 4096' \
  < scripts/dut_prepare.sh

scripts/run_paired.sh \
  --rates "$rates" \
  --uninstrumented-rates 14m,14880952 \
  --expect-rx-ring 4096 \
  --reps 10 \
  --duration 30 \
  --cell-warmup 5 \
  --plan
```

Remove `--plan` after the 4096-descriptor readiness checks pass. The archived
campaign is under `data/paired/paired_4config_ring4096_20260824/`.

### 12. Restore both hosts

Stop TRex on the tester and rebind its X520 ports to `ixgbe`:

```bash
scripts/trex_stop.sh
```

Restore the DUT runtime settings:

```bash
ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1' \
  < scripts/dut_restore.sh
```

Pass `nic` after the interface to restore the original multi-queue setting.
Boot-time CPU isolation remains active until it is removed separately.

## Metrics and validity checks

`run_cell.sh` measures a complete receive path over one steady window. The
cycle count therefore covers the queue interrupt, driver, NAPI, and XDP
program. Generic mode also includes work that precedes the generic XDP hook.

Each instrumented cell records these primary quantities:

- Processed packets from the DUT `rx_packets` counter.
- Pre-XDP loss from `rx_missed_errors` relative to realized offered load.
- Active core cycles per processed packet.
- Demand-data fills per processed packet from local L2, local cache complex,
  and local DRAM.
- Generator, path, NIC, CPU, and timing cross-checks.

The raw PMU events are `cycles`, `instructions`, `branch-misses`, `r0143`,
`r0243`, and `r0843`. The final three events count fills served by local L2,
local cache complex, and local DRAM. The measured mapping is documented under
`data/artifacts/`.

A cell is valid only when all implemented checks pass. The checks include
packet conservation, path-counter agreement, no material DUT transmission,
stable DUT state, no TRex transmit errors, and full PMU event runtime.
`run_cell.sh` stores every failure reason in `invalid_reasons`.

The paper classifies a load as processing-limited when its median pre-XDP loss
exceeds 0.1 percent. The saturation onset is the lowest offered load that meets
this condition. The paper computes each paired difference within one block as
`read-data` minus `no-touch`. It reports medians, observed ranges, and sign
counts as descriptive variation on this testbed.

## Output files

One paired campaign directory contains:

| File | Purpose |
|---|---|
| `campaign.json` | Frozen design, timing, rate grid, and requested settings |
| `manifest.json` | DUT and tester hardware, software, firmware, and configuration |
| `cells/*.json` | Raw measurements and validity verdicts |
| `cells/*.state` | DUT state before and after each cell |
| `summary.tsv` | One analysis row per attempted cell |
| `analysis.txt` | Generated paired report |

The raw cell files and manifests are authoritative. `summary.tsv` and
`analysis.txt` are derived files. The `file` column in an archived summary
contains the original absolute collection path. Locate the portable copy by its
basename in the campaign's `cells/` directory.

## Script inventory

### Paper workflow

| Script | Role |
|---|---|
| `trex_start.sh` | Start TRex and bind tester ports to DPDK |
| `trex_stop.sh` | Stop TRex and restore the tester ports |
| `dut_prepare.sh` | Configure the single-core DUT state |
| `dut_audit.sh` | Run the general pre-campaign audit |
| `final_dut_audit.sh` | Check the exact original DUT runtime state |
| `validate_generator.sh` | Validate offered load through line rate |
| `measure_baseline_linerate.sh` | Measure the native no-touch line-rate baseline |
| `run_cell.sh` | Run and validate one measurement cell |
| `run_paired.sh` | Run the four-configuration paired campaign |
| `analyse_paired.py` | Generate the paired text report |
| `make_results_figure.py` | Generate the paper's plot data tables |
| `manifest.sh` | Record testbed provenance for a campaign |
| `pmc/pmc_probe.sh` | Validate the Zen 1 PMCx043 source masks |

### Internal DUT helpers

`run_cell.sh` uploads and invokes these helpers. They are not normal entry
points for a campaign:

| Script | Role |
|---|---|
| `dut_path.sh` | Install, verify, count, and remove a packet path |
| `dut_state.sh` | Capture drift-sensitive DUT state around a cell |
| `dut_measure_window.sh` | Bracket PMU and packet counters in one DUT session |
| `dut_cpu_activity.sh` | Trace tasks and interrupts on the measurement CPU |

### Scope of the shipped scripts

The scripts install, verify, and measure one packet path, `xdp_drop`, with the
`xdp-bench` `no-touch` and `read-data` operations at the native and generic XDP
hooks. `dut_path.sh` and `dut_audit.sh` still assert that no `iptables` rule and
no `nftables` table is active, because a leftover rule would discard packets
ahead of the XDP hook and change the measurement.
