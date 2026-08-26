#!/usr/bin/env bash
# dut_audit.sh -- read-only verification of the DuT measurement state.
# Prints OK/FAIL per check; exits non-zero if any FAIL.
#
#   ssh dut@192.168.137.50 'sudo bash -s -- enp35s0f1 10' < scripts/dut_audit.sh
#
# Args: $1 = interface (default enp35s0f1)   $2 = measurement CPU (default 10)
set -uo pipefail
IFACE="${1:-enp35s0f1}"
CPU="${2:-10}"
fail=0
chk() { # label  expected  actual
  if [ "$2" = "$3" ]; then printf '  OK   %-30s %s\n' "$1" "$3"
  else printf '  FAIL %-30s got:%s want:%s\n' "$1" "$3" "$2"; fail=1; fi
}

echo "== DuT audit: $IFACE, cpu$CPU =="

# persistent isolation (boot cmdline)
iso=$(cat /sys/devices/system/cpu/isolated 2>/dev/null)
chk "isolcpus"      "10-11" "$iso"
nz=$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null)
chk "nohz_full"     "10-11" "$nz"

# NIC
comb=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Current/{f=1} f&&/Combined:/{print $2; exit}')
chk "combined queues" "1" "$comb"
fc=$(ethtool -a "$IFACE" 2>/dev/null | awk '/RX:/{r=$2} /TX:/{t=$2} END{print r"/"t}')
if [ "$fc" = "off/off" ]; then printf '  OK   %-30s %s\n' "flow control rx/tx" "$fc"
else printf '  WARN %-30s %s (benign: TRex/DPDK ignores PAUSE; DuT sheds as rx_missed)\n' "flow control rx/tx" "$fc"; fi
bps=$(cat /proc/sys/kernel/bpf_stats_enabled 2>/dev/null)
chk "bpf_stats_enabled" "0" "$bps"
link=$(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null)
chk "link" "up" "$link"

# CPU
gov=$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_governor 2>/dev/null)
chk "governor cpu$CPU" "performance" "$gov"
smt=$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)
chk "SMT" "off" "$smt"
boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)
chk "boost" "0" "$boost"
online=$(cat /sys/devices/system/cpu/online 2>/dev/null)
if grep -qw "$CPU" <(tr ',' ' ' <<<"$online" | tr '-' ' '); then :; fi
printf '  --   %-30s %s\n' "online cpus" "$online"

# IRQ affinity of the queue
# IRQ affinity is dynamic: every native attach/detach resets it, and run_cell.sh
# re-pins + verifies it per cell. So this is informational (WARN), not a hard gate.
IRQ=$(grep -i "${IFACE}-TxRx-0" /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1;exit}')
aff=$(cat /proc/irq/"${IRQ:-none}"/effective_affinity_list 2>/dev/null || echo "?")
if [ "$aff" = "$CPU" ]; then printf '  OK   %-30s %s\n' "queue IRQ${IRQ:+ $IRQ} eff.aff" "$aff"
else printf '  WARN %-30s got:%s want:%s (run_cell re-pins per attach)\n' "queue IRQ${IRQ:+ $IRQ} eff.aff" "$aff" "$CPU"; fi

# clock: with governor=performance and boost off the core must sit at its max
cur=$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_cur_freq 2>/dev/null)
max=$(cat /sys/devices/system/cpu/cpu"$CPU"/cpufreq/scaling_max_freq 2>/dev/null)
chk "cpu$CPU clock == max kHz" "$max" "$cur"

# Connection tracking must not sit in the measured path.
ct=$(lsmod 2>/dev/null | grep -c '^nf_conntrack')
chk "nf_conntrack loaded" "0" "$ct"

# The path under test is installed per cell by run_cell.sh. Between cells the
# DuT must be clean, otherwise two paths would be measured at once.
xt=$(iptables-legacy -t raw -S PREROUTING 2>/dev/null | grep -c -- '-j DROP')
chk "legacy raw DROP rules" "0" "$xt"
xn=$(iptables-nft -t raw -S PREROUTING 2>/dev/null | grep -c -- '-j DROP')
chk "iptables-nft raw DROP rules" "0" "$xn"
all_nt=$(nft list tables 2>/dev/null | grep -c .)
chk "all nft tables" "0" "$all_nt"

# XDP attachment (informational)
# Leftover state, checked the same way as leftover iptables rules and nft
# tables. Before a campaign nothing may be attached. An orphaned program would
# pass path verification, which only asks whether an XDP program is attached and
# not whose it is, so the first cell would measure a program it did not start.
xdp=$(ip -d link show "$IFACE" 2>/dev/null | grep -oiE 'xdpgeneric|xdp' | head -1)
# run_cell.sh detaches this in its preflight before every cell, so it is
# informational and not a hard gate, exactly like the queue IRQ affinity above.
# It still deserves reporting: an orphan would otherwise pass path verification
# unnoticed, and seeing it here tells you an earlier run did not finish.
if [ -z "$xdp" ]; then printf '  OK   %-30s %s\n' "xdp attached" "none"
else printf '  WARN %-30s %s (run_cell clears it per cell)\n' "xdp attached" "$xdp"; fi

# An interrupted cell leaves its bench running. It keeps polling on the
# measurement core and its program stays attached after the cell is gone.
# A failing systemctl must not turn into a count of zero. Report that the check
# could not run instead of passing it.
if bench_raw=$(systemctl list-units --all --no-legend 'xdpbench-cell-*' 2>/dev/null); then
  bench=$(printf '%s\n' "$bench_raw" | grep -c . || true)
else
  bench=unknown
fi
# Also cleared by run_cell.sh per cell, so WARN rather than FAIL. A systemd
# query that does not answer is a different matter and stays a failure.
if [ "$bench" = 0 ]; then printf '  OK   %-30s %s\n' "orphaned xdp-bench units" "0"
elif [ "$bench" = unknown ]; then
  printf '  FAIL %-30s %s\n' "orphaned xdp-bench units" "could not query systemd"; fail=1
else printf '  WARN %-30s %s (run_cell stops them per cell)\n' "orphaned xdp-bench units" "$bench"; fi

# The measured path and the CPU-isolation tracer must be available.
for b in xdp-bench bpftrace; do
  command -v "$b" >/dev/null && printf '  OK   %-30s %s\n' "$b available" "yes" \
    || { printf '  FAIL %-30s %s\n' "$b available" "no"; fail=1; }
done

echo "== $( [ $fail -eq 0 ] && echo "ALL OK" || echo "FAILURES PRESENT" ) =="
exit $fail
