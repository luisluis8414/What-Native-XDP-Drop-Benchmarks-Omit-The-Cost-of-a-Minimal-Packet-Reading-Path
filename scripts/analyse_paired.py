#!/usr/bin/env python3
"""Analyse one mode x variant block campaign.

The current summary format contains four configurations per offered-load block:
native/no-touch, native/read-data, skb/no-touch, and skb/read-data. The report
shows each within-hook effect and their cross-hook difference of differences.

The script reports pair counts, signs, range gaps, and every block difference.
These are descriptive summaries of run variation on the recorded testbed.

Older summaries without a ``mode`` column remain readable as one unspecified
hook.

Usage:
    scripts/analyse_paired.py data/paired/<label>/summary.tsv /dev/stdout \
        no-touch read-data
"""

import csv
import statistics as st
import sys
from collections import defaultdict


LOSS_THRESHOLD = 0.001


def median_range(values):
    return st.median(values), min(values), max(values)


def mode_label(mode):
    return "skb (generic)" if mode == "skb" else mode


def main():
    summary, out_path, var_a, var_b = sys.argv[1:5]
    with open(summary, newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        rows = list(reader)
        has_mode = "mode" in (reader.fieldnames or [])

    valid, invalid, failed = [], [], []
    for row in rows:
        if row["valid"] == "NA":
            failed.append(row)
        elif row["valid"] == "True":
            valid.append(row)
        else:
            invalid.append(row)

    if not valid:
        sys.exit("ERROR: no valid cells in " + summary)

    for row in valid:
        row["rate"] = int(row["rate"])
        row["block"] = int(row["block"])
        row["inst"] = row["instrumented"] == "1"
        row["mode"] = row.get("mode") or "unspecified"
        for key in ("accepted_pps", "loss", "cycles_per_pkt"):
            row[key] = float(row[key])

    modes = list(dict.fromkeys((row.get("mode") or "unspecified") for row in rows))
    if "native" in modes and "skb" in modes:
        modes = ["native", "skb"] + [m for m in modes if m not in {"native", "skb"}]

    out = []
    write = out.append
    write("FOUR-CONFIGURATION BLOCK ANALYSIS" if has_mode else "PAIRED RUN ANALYSIS")
    write("")
    write(f"valid cells {len(valid)}, invalid {len(invalid)}, failed {len(failed)}")
    write("No inferential or established/not-established verdict is produced.")
    write("Check that every intended block is present before interpreting differences.")
    if invalid:
        write("")
        write("Invalid cells are excluded. Reasons:")
        reasons = defaultdict(int)
        for row in invalid:
            reasons[row["invalid_reasons"]] += 1
        for reason, count in sorted(reasons.items(), key=lambda item: -item[1]):
            write(f"  {count:3d}x {reason}")

    inst = [row for row in valid if row["inst"]]
    rates = sorted({row["rate"] for row in inst})

    write("")
    write("BLOCK COMPLETENESS (valid instrumented cells)")
    expected = {(mode, variant) for mode in modes for variant in (var_a, var_b)}
    for rate in rates:
        by_block = defaultdict(set)
        for row in inst:
            if row["rate"] == rate:
                by_block[row["block"]].add((row["mode"], row["variant"]))
        complete = [block for block, configs in by_block.items() if configs == expected]
        write(f"  {rate/1e6:8.3f} Mpps: {len(complete)}/{len(by_block)} complete blocks")
        for block, configs in sorted(by_block.items()):
            missing = expected - configs
            if missing:
                text = ", ".join(f"{mode}/{variant}" for mode, variant in sorted(missing))
                write(f"      block {block}: missing {text}")

    write("")
    write("COST AND THROUGHPUT PER LOAD (instrumented cells)")
    write("")
    write(
        f"{'Mpps':>8} {'hook':>13} {'variant':>10} {'n':>3} {'cyc/pkt med':>12} "
        f"{'min':>9} {'max':>9} {'acc Mpps':>9} {'loss %':>8}"
    )
    per = {}
    for rate in rates:
        for mode in modes:
            for variant in (var_a, var_b):
                cells = [
                    row for row in inst
                    if row["rate"] == rate and row["mode"] == mode
                    and row["variant"] == variant
                ]
                if not cells:
                    continue
                cpp = [row["cycles_per_pkt"] for row in cells]
                accepted = [row["accepted_pps"] for row in cells]
                per[(mode, rate, variant)] = {"cpp": cpp, "accepted": accepted}
                med, low, high = median_range(cpp)
                loss = st.median([row["loss"] for row in cells])
                write(
                    f"{rate/1e6:8.3f} {mode_label(mode):>13} {variant:>10} "
                    f"{len(cells):3d} {med:12.1f} {low:9.1f} {high:9.1f} "
                    f"{st.median(accepted)/1e6:9.3f} {100*loss:8.3f}"
                )

    write("")
    write("REGIME CLASSIFICATION")
    write(f"processing-limited when median pre-XDP loss exceeds {100*LOSS_THRESHOLD:.1f}%")
    write("processing plateau is the mean processed load across all blocks at processing-limited loads")
    for mode in modes:
        for variant in (var_a, var_b):
            available = [rate for rate in rates if (mode, rate, variant) in per]
            if not available:
                continue
            write("")
            write(f"  {mode_label(mode)}/{variant}:")
            limited_rates = []
            for rate in available:
                cells = [
                    row for row in inst
                    if row["rate"] == rate and row["mode"] == mode
                    and row["variant"] == variant
                ]
                loss = st.median([row["loss"] for row in cells])
                accepted = st.median(per[(mode, rate, variant)]["accepted"])
                regime = "processing-limited" if loss > LOSS_THRESHOLD else "unsaturated or link-limited"
                if loss > LOSS_THRESHOLD:
                    limited_rates.append(rate)
                write(
                    f"    {rate/1e6:8.3f} Mpps  median {accepted/1e6:7.3f} Mpps  "
                    f"loss {100*loss:6.3f}%  {regime}"
                )
            if limited_rates:
                plateau = [
                    accepted
                    for rate in limited_rates
                    for accepted in per[(mode, rate, variant)]["accepted"]
                ]
                write(
                    f"    -> processing plateau {st.mean(plateau)/1e6:.3f} Mpps "
                    f"(mean of {len(plateau)} blocks across {len(limited_rates)} loads)"
                )
            else:
                top = available[-1]
                top_accepted = st.median(per[(mode, top, variant)]["accepted"])
                write(f"    -> link-limited, capacity at least {top_accepted/1e6:.3f} Mpps")

    write("")
    write(f"WITHIN-HOOK BLOCK DIFFERENCES, {var_b} minus {var_a}")
    write("Positive range gap means the two pooled variant ranges do not overlap.")
    write("The individual block differences below show variation across repetitions.")
    write("")
    write(
        f"{'Mpps':>8} {'hook':>13} {'pairs':>6} {'median diff':>12} "
        f"{'% of base':>10} {'signs':>10} {'range gap':>10}"
    )
    effects = {}
    for rate in rates:
        for mode in modes:
            by_block = defaultdict(dict)
            for row in inst:
                if row["rate"] == rate and row["mode"] == mode:
                    by_block[row["block"]][row["variant"]] = row["cycles_per_pkt"]
            pairs = [
                (block, values[var_b] - values[var_a])
                for block, values in sorted(by_block.items())
                if var_a in values and var_b in values
            ]
            if not pairs:
                continue
            effects[(mode, rate)] = dict(pairs)
            diffs = [diff for _, diff in pairs]
            median_diff = st.median(diffs)
            base_cells = per.get((mode, rate, var_a), {}).get("cpp", [])
            touch_cells = per.get((mode, rate, var_b), {}).get("cpp", [])
            base = st.median(base_cells) if base_cells else 0
            same_sign = all(diff > 0 for diff in diffs) or all(diff < 0 for diff in diffs)
            if base_cells and touch_cells:
                gap = (
                    min(touch_cells) - max(base_cells)
                    if median_diff > 0 else min(base_cells) - max(touch_cells)
                )
            else:
                gap = float("nan")
            write(
                f"{rate/1e6:8.3f} {mode_label(mode):>13} {len(diffs):6d} "
                f"{median_diff:12.1f} {100*median_diff/base if base else 0:10.2f} "
                f"{'all same' if same_sign else 'mixed':>10} {gap:10.1f}"
            )
            write("         " + " ".join(f"b{block}:{diff:+.1f}" for block, diff in pairs))

    if "native" in modes and "skb" in modes:
        write("")
        write("CROSS-HOOK DIFFERENCE OF DIFFERENCES")
        write(f"({var_b} - {var_a}) native minus ({var_b} - {var_a}) skb")
        write("")
        write(f"{'Mpps':>8} {'blocks':>6} {'median':>10} {'min':>10} {'max':>10} {'signs':>10}")
        for rate in rates:
            native = effects.get(("native", rate), {})
            generic = effects.get(("skb", rate), {})
            blocks = sorted(set(native) & set(generic))
            diffs = [native[block] - generic[block] for block in blocks]
            if not diffs:
                continue
            same_sign = all(diff > 0 for diff in diffs) or all(diff < 0 for diff in diffs)
            write(
                f"{rate/1e6:8.3f} {len(blocks):6d} {st.median(diffs):10.1f} "
                f"{min(diffs):10.1f} {max(diffs):10.1f} "
                f"{'all same' if same_sign else 'mixed':>10}"
            )
            write("         " + " ".join(f"b{block}:{diff:+.1f}" for block, diff in zip(blocks, diffs)))

    uninstrumented_rates = sorted({row["rate"] for row in valid if not row["inst"]})
    write("")
    write("INSTRUMENTATION CHECK")
    if not uninstrumented_rates:
        write("  no uninstrumented cells, run with --uninstrumented-rates to bound this")
    else:
        write("  positive diff means instrumented throughput is higher")
        write("")
        write(f"{'Mpps':>8} {'hook':>13} {'variant':>10} {'with':>10} {'without':>10} {'diff %':>8}")
        for rate in uninstrumented_rates:
            for mode in modes:
                for variant in (var_a, var_b):
                    with_counters = [
                        row["accepted_pps"] for row in valid
                        if row["inst"] and row["rate"] == rate
                        and row["mode"] == mode and row["variant"] == variant
                    ]
                    without_counters = [
                        row["accepted_pps"] for row in valid
                        if not row["inst"] and row["rate"] == rate
                        and row["mode"] == mode and row["variant"] == variant
                    ]
                    if not with_counters or not without_counters:
                        continue
                    on = st.median(with_counters)
                    off = st.median(without_counters)
                    write(
                        f"{rate/1e6:8.3f} {mode_label(mode):>13} {variant:>10} "
                        f"{on/1e6:10.3f} {off/1e6:10.3f} "
                        f"{100*(on/off-1) if off else 0:8.3f}"
                    )

    text = "\n".join(out) + "\n"
    with open(out_path, "w") as stream:
        stream.write(text)
    if out_path != "/dev/stdout":
        print()
        print(text)


if __name__ == "__main__":
    main()
