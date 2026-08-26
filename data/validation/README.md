# Validation data

This directory contains gatekeeping measurements for the testbed. These checks
validate the traffic generator and CPU isolation. They do not replace the
four-configuration campaign under `data/paired/`.

Both validations were recorded while the DUT used an RX ring with 4096
descriptors. The paper's primary campaign uses 512 descriptors. Generator
capacity and CPU isolation do not provide packet-read cost results.

## Directory layout

| Directory | Purpose |
|---|---|
| `generator_20260823T122402Z/` | Validate offered load through 10 GbE line rate |
| `cpu10_20260823T121751Z/` | Check foreign work on measurement CPU 10 |

## Generator capacity

The generator validation requested 14, 14.5, and 14.880952 million packets per
second. Each rate ran five times for 30 seconds. TRex sent one constant-rate
flow of 64-byte Ethernet frames. The DUT used `xdp-filter` as a packet sink.

The generator produced these median rates from its transmitted packet counts:

| Requested rate | Repetitions | Achieved rate | TRex errors | DUT cross-check |
|---:|---:|---:|---:|---:|
| 14.000000 Mpps | 5 | 14.0001 Mpps | 0 | 1.00000 |
| 14.500000 Mpps | 5 | 14.5001 Mpps | 0 | 1.00000 |
| 14.880952 Mpps | 5 | 14.8808 Mpps | 0 | 1.00000 |

At line rate, the generator reached 99.999 percent of the theoretical
14.880952 Mpps rate. It reported no transmit errors in any of the 15 runs. The
DUT observed every transmitted frame through `rx_packets` plus
`rx_missed_errors`.

The ceiling probe requested 15,380,952 packets per second. TRex rejected this
request because its expected 10.336 Gbit/s load exceeded the 10 Gbit/s port
rate. The result confirms that the configured load cannot exceed the physical
link rate.

The files have these roles:

| File | Content |
|---|---|
| `analysis.txt` | Human-readable summary across all runs |
| `runs.tsv` | One row per rate and repetition |
| `run_*.json` | Raw TRex and DUT counters for one run |
| `ceiling_probe.txt` | Expected rejection of the above-line-rate request |
| `manifest.json` | Exact DUT and tester environment |

`runs.tsv` and the raw JSON files are the measurement records. `analysis.txt`
is derived from those records.

## CPU isolation

The CPU validation ran native XDP `no-touch` at a requested 14.2 Mpps. The
measurement used CPU 10, a 5-second warm-up, and one 30-second measured window.

The JSON record reports `clean: true`. During the observed window it found:

- Zero foreign task schedule-ins on CPU 10.
- Zero foreign hardware interrupts on CPU 10.
- Zero foreign softirqs on CPU 10.
- Zero scheduler softirqs on CPU 10.
- 154 interrupts from the expected receive queue.
- 6,565,816 expected `NET_RX` softirqs.

The record separates expected receive-path work from local kernel activity.
It also reports four `perf` schedule-ins, four `migration/10` schedule-ins, and
16 `ksoftirqd/10` schedule-ins in their respective categories.

The measurement cell remained valid and its recorded DUT settings stayed
unchanged. Packet conservation was 1.0000 and the PMU events ran for 100 percent
of the window.

This check covers one window and one configuration. It demonstrates clean CPU
isolation for that run, not for every later cell. Each campaign cell therefore
also records its DUT state before and after the measured window.

The two files have these roles:

| File | Content |
|---|---|
| `20260823T121751Z_xdp_drop_14200000.json` | Measurement and CPU-activity result |
| `20260823T121751Z_xdp_drop_14200000.state` | DUT state before and after the window |
