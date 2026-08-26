#!/usr/bin/env bash
# Measure task and interrupt activity on one DUT CPU over a fixed window.
#
# The script runs on the DUT as root. It pins its userspace instrumentation to a
# housekeeping CPU, then uses a bpftrace sched_switch trace to observe which
# non-idle tasks actually run on the measurement CPU. Counter deltas from
# /proc/interrupts and /proc/softirqs distinguish the expected receive path from
# unrelated interrupt work. The JSON output is intended for a per-trial manifest.
set -euo pipefail

CPU=10
HOUSEKEEPING_CPU=0
IFACE=enp35s0f1
DURATION=30

usage() {
  echo "usage: $0 [--cpu N] [--housekeeping-cpu N] [--iface IFACE] [--duration S]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cpu) CPU=$2; shift 2 ;;
    --housekeeping-cpu) HOUSEKEEPING_CPU=$2; shift 2 ;;
    --iface) IFACE=$2; shift 2 ;;
    --duration) DURATION=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$CPU" =~ ^[0-9]+$ ]] || { echo "invalid --cpu: $CPU" >&2; exit 2; }
[[ "$HOUSEKEEPING_CPU" =~ ^[0-9]+$ ]] \
  || { echo "invalid --housekeeping-cpu: $HOUSEKEEPING_CPU" >&2; exit 2; }
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] \
  || { echo "invalid --duration: $DURATION" >&2; exit 2; }
[ "$CPU" -ne "$HOUSEKEEPING_CPU" ] \
  || { echo "measurement and housekeeping CPU must differ" >&2; exit 2; }
[ "$EUID" -eq 0 ] || { echo "run this script as root" >&2; exit 1; }
[ -d "/sys/devices/system/cpu/cpu$CPU" ] \
  || { echo "cpu$CPU does not exist" >&2; exit 1; }
[ -d "/sys/devices/system/cpu/cpu$HOUSEKEEPING_CPU" ] \
  || { echo "cpu$HOUSEKEEPING_CPU does not exist" >&2; exit 1; }
[ -d "/sys/class/net/$IFACE" ] \
  || { echo "interface $IFACE does not exist" >&2; exit 1; }
command -v bpftrace >/dev/null || { echo "bpftrace is unavailable" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is unavailable" >&2; exit 1; }

# Keep the shell, bpftrace process, parser, and timer off the measurement CPU.
taskset -pc "$HOUSEKEEPING_CPU" "$$" >/dev/null

EXPECTED_IRQ=$(awk -F: -v pattern="${IFACE}-TxRx-0" '
  index($0, pattern) { irq=$1; gsub(/[[:space:]]/, "", irq); print irq; exit }
' /proc/interrupts)
[ -n "$EXPECTED_IRQ" ] \
  || { echo "could not find ${IFACE}-TxRx-0 in /proc/interrupts" >&2; exit 1; }

TMP_DIR=$(mktemp -d /tmp/xdp3-cpu-activity.XXXXXX)
BT_OUT="$TMP_DIR/bpftrace.out"
BT_ERR="$TMP_DIR/bpftrace.err"
INT_BEFORE="$TMP_DIR/interrupts.before"
INT_AFTER="$TMP_DIR/interrupts.after"
SOFT_BEFORE="$TMP_DIR/softirqs.before"
SOFT_AFTER="$TMP_DIR/softirqs.after"
BT_PID=""

cleanup() {
  if [ -n "$BT_PID" ] && kill -0 "$BT_PID" 2>/dev/null; then
    kill -INT "$BT_PID" 2>/dev/null || true
    wait "$BT_PID" 2>/dev/null || true
  fi
  rm -f "$BT_OUT" "$BT_ERR" "$INT_BEFORE" "$INT_AFTER" \
    "$SOFT_BEFORE" "$SOFT_AFTER"
  rmdir "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

KSOFTIRQD="ksoftirqd/$CPU"
MIGRATION="migration/$CPU"
BPF_PROGRAM=$(printf '%s\n' \
  'BEGIN { printf("__XDP3_READY__\n"); }' \
  "tracepoint:sched:sched_switch /cpu == $CPU && args.next_pid != 0 && str(args.next_comm) == \"$KSOFTIRQD\"/ { @packet_task[str(args.next_comm)] = count(); }" \
  "tracepoint:sched:sched_switch /cpu == $CPU && args.next_pid != 0 && str(args.next_comm) == \"perf\"/ { @measurement_task[str(args.next_comm)] = count(); }" \
  "tracepoint:sched:sched_switch /cpu == $CPU && args.next_pid != 0 && str(args.next_comm) == \"$MIGRATION\"/ { @kernel_task[str(args.next_comm)] = count(); }" \
  "tracepoint:sched:sched_switch /cpu == $CPU && args.next_pid != 0 && str(args.next_comm) != \"$KSOFTIRQD\" && str(args.next_comm) != \"perf\" && str(args.next_comm) != \"$MIGRATION\"/ { @foreign_task[str(args.next_comm)] = count(); }")

taskset -c "$HOUSEKEEPING_CPU" bpftrace -B none -q -e "$BPF_PROGRAM" \
  >"$BT_OUT" 2>"$BT_ERR" &
BT_PID=$!

READY=0
for _ in $(seq 1 100); do
  if grep -q '^__XDP3_READY__$' "$BT_OUT"; then
    READY=1
    break
  fi
  kill -0 "$BT_PID" 2>/dev/null \
    || { echo "bpftrace exited before becoming ready: $(cat "$BT_ERR")" >&2; exit 1; }
  sleep 0.05
done
[ "$READY" -eq 1 ] \
  || { echo "bpftrace did not become ready: $(cat "$BT_ERR")" >&2; exit 1; }

cp /proc/interrupts "$INT_BEFORE"
cp /proc/softirqs "$SOFT_BEFORE"
START_NS=$(date +%s%N)
taskset -c "$HOUSEKEEPING_CPU" sleep "$DURATION"
END_NS=$(date +%s%N)
cp /proc/interrupts "$INT_AFTER"
cp /proc/softirqs "$SOFT_AFTER"

kill -INT "$BT_PID"
wait "$BT_PID" || true
BT_PID=""

taskset -c "$HOUSEKEEPING_CPU" python3 - \
  "$CPU" "$HOUSEKEEPING_CPU" "$DURATION" "$START_NS" "$END_NS" \
  "$EXPECTED_IRQ" "$BT_OUT" "$INT_BEFORE" "$INT_AFTER" \
  "$SOFT_BEFORE" "$SOFT_AFTER" <<'PY'
import json
import re
import sys

(
    cpu,
    housekeeping_cpu,
    duration,
    start_ns,
    end_ns,
    expected_irq,
    bpf_path,
    interrupts_before,
    interrupts_after,
    softirqs_before,
    softirqs_after,
) = sys.argv[1:]
cpu = int(cpu)
housekeeping_cpu = int(housekeeping_cpu)


def parse_counter_file(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    cpus = lines[0].split()
    column = cpus.index(f"CPU{cpu}")
    counters = {}
    descriptions = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        label, values = line.split(":", 1)
        label = label.strip()
        fields = values.split()
        if len(fields) <= column or not fields[column].isdigit():
            continue
        counters[label] = int(fields[column])
        descriptions[label] = " ".join(fields[len(cpus):])
    return counters, descriptions


def positive_deltas(before_path, after_path):
    before, _ = parse_counter_file(before_path)
    after, descriptions = parse_counter_file(after_path)
    deltas = {}
    for label, value in after.items():
        delta = value - before.get(label, value)
        if delta > 0:
            description = descriptions.get(label, "")
            key = f"{label} {description}".strip()
            deltas[key] = delta
    return deltas


foreign_tasks = {}
packet_tasks = {}
measurement_tasks = {}
kernel_tasks = {}
map_line = re.compile(
    r"^@(foreign_task|packet_task|measurement_task|kernel_task)\[(.*)\]:\s+(\d+)$"
)
for line in open(bpf_path, encoding="utf-8"):
    match = map_line.match(line.strip())
    if not match:
        continue
    target = {
        "foreign_task": foreign_tasks,
        "packet_task": packet_tasks,
        "measurement_task": measurement_tasks,
        "kernel_task": kernel_tasks,
    }[match.group(1)]
    target[match.group(2)] = int(match.group(3))

interrupt_deltas = positive_deltas(interrupts_before, interrupts_after)
expected_interrupts = {}
kernel_interrupts = {}
foreign_interrupts = {}
for key, value in interrupt_deltas.items():
    label = key.split(maxsplit=1)[0]
    if label == expected_irq:
        target = expected_interrupts
    elif label.isdigit():
        target = foreign_interrupts
    else:
        target = kernel_interrupts
    target[key] = value

softirq_deltas = positive_deltas(softirqs_before, softirqs_after)
expected_net_rx = {}
scheduler_softirqs = {}
kernel_softirqs = {}
foreign_softirqs = {}
for key, value in softirq_deltas.items():
    label = key.split(maxsplit=1)[0]
    if label == "NET_RX":
        target = expected_net_rx
    elif label == "SCHED":
        target = scheduler_softirqs
    elif label in {"TIMER", "RCU"}:
        target = kernel_softirqs
    else:
        target = foreign_softirqs
    target[key] = value

foreign_task_count = sum(foreign_tasks.values())
foreign_interrupt_count = sum(foreign_interrupts.values())
foreign_softirq_count = sum(foreign_softirqs.values())

result = {
    "measurement_cpu": cpu,
    "housekeeping_cpu": housekeeping_cpu,
    "requested_window_s": int(duration),
    "observed_window_s": (int(end_ns) - int(start_ns)) / 1e9,
    "expected_queue_irq": int(expected_irq),
    "task_schedule_ins": {
        "foreign": foreign_task_count,
        "foreign_by_comm": foreign_tasks,
        "measurement": sum(measurement_tasks.values()),
        "measurement_by_comm": measurement_tasks,
        "kernel_internal": sum(kernel_tasks.values()),
        "kernel_internal_by_comm": kernel_tasks,
        "packet_ksoftirqd": sum(packet_tasks.values()),
        "packet_ksoftirqd_by_comm": packet_tasks,
    },
    "hardware_interrupts": {
        "expected_queue": sum(expected_interrupts.values()),
        "expected_queue_breakdown": expected_interrupts,
        "foreign": foreign_interrupt_count,
        "foreign_breakdown": foreign_interrupts,
        "kernel_internal": sum(kernel_interrupts.values()),
        "kernel_internal_breakdown": kernel_interrupts,
    },
    "softirqs": {
        "expected_net_rx": sum(expected_net_rx.values()),
        "expected_net_rx_breakdown": expected_net_rx,
        "scheduler": sum(scheduler_softirqs.values()),
        "scheduler_breakdown": scheduler_softirqs,
        "kernel_internal": sum(kernel_softirqs.values()),
        "kernel_internal_breakdown": kernel_softirqs,
        "foreign": foreign_softirq_count,
        "foreign_breakdown": foreign_softirqs,
    },
    "clean": (
        foreign_task_count == 0
        and foreign_interrupt_count == 0
        and foreign_softirq_count == 0
    ),
}
print(json.dumps(result, indent=2, sort_keys=True))
PY
