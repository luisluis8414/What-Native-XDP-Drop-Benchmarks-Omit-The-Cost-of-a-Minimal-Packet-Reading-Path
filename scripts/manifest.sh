#!/usr/bin/env bash
# manifest.sh -- capture the full testbed environment (DuT + tester) as a JSON
# provenance manifest for one measurement campaign. It records everything that
# can change a number and must be pinned for reproducibility: kernel, CPU +
# microcode, NIC driver/firmware/PCIe link, CPU vulnerability mitigations (the
# DuT runs retpolines; the original paper disabled them), the isolation state,
# and tool versions. Campaign wrappers embed this in every output directory.
#
# Usage:
#   scripts/manifest.sh                        # JSON on stdout
#   scripts/manifest.sh > data/manifest.json
#
# Options (defaults in []):
#   --iface IFACE   [enp35s0f1]
#   --cpu   N       [10]
#   --host  u@h     [dut@192.168.137.50]
#   --trex-dir DIR  [/opt/trex/v3.08]     (TRex version taken from the dir name)
#   --tester-nic ID [8086:10fb]           (X520 PCI vendor:device on the tester)
set -uo pipefail

IFACE=enp35s0f1 CPU=10 HOST=dut@192.168.137.50 TREX_DIR=/opt/trex/v3.08 TESTER_NIC=8086:10fb
while [ $# -gt 0 ]; do case "$1" in
  --iface) IFACE=$2; shift 2;; --cpu) CPU=$2; shift 2;; --host) HOST=$2; shift 2;;
  --trex-dir) TREX_DIR=$2; shift 2;; --tester-nic) TESTER_NIC=$2; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;; esac; done

SSH=(ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST")
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TMP=$(mktemp)

# ---- DuT: one round-trip, emit "dut.<key>\t<value>" lines ----
"${SSH[@]}" "bash -s -- $IFACE $CPU" >>"$TMP" <<'REMOTE'
IFACE="$1"; CPU="$2"
p(){ printf 'dut.%s\t%s\n' "$1" "$2"; }
p kernel   "$(uname -r)"
p os       "$(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")"
p cpu_model "$(awk -F: '/model name/{sub(/^ /,"",$2);print $2; exit}' /proc/cpuinfo)"
mem_dmi="$(sudo -n dmidecode --type 17 2>/dev/null)"
dmi_installed_field(){
  printf '%s\n' "$mem_dmi" | awk -v key="$1" '
    BEGIN { RS=""; FS="\n" }
    $0 ~ /Size: [0-9]+ (MB|GB|TB)/ {
      for (i=1; i<=NF; i++) {
        line=$i
        sub(/^[ \t]+/, "", line)
        if (index(line, key ":") == 1) {
          sub(/^[^:]+:[ \t]*/, "", line)
          printf "%s%s", sep, line
          sep=", "
          break
        }
      }
    }'
}
p memory_total_kib "$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)"
p memory_dimm_sizes "$(dmi_installed_field Size)"
p memory_dimm_part_numbers "$(dmi_installed_field 'Part Number')"
p memory_dimm_ranks "$(dmi_installed_field Rank)"
p memory_dimm_channels "$(dmi_installed_field 'Bank Locator')"
p memory_speed_smbios "$(dmi_installed_field Speed | awk -F', ' '{print $1}')"
p memory_configured_speed_smbios "$(dmi_installed_field 'Configured Memory Speed' | awk -F', ' '{print $1}')"
p numa_nodes "$(find /sys/devices/system/node -mindepth 1 -maxdepth 1 -type d -name 'node*' | wc -l)"
p numa_node0_cpus "$(cat /sys/devices/system/node/node0/cpulist 2>/dev/null)"
p microcode "$(awk -F: '/microcode/{gsub(/ /,"",$2);print $2; exit}' /proc/cpuinfo)"
p governor "$(cat /sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_governor 2>/dev/null)"
p cur_khz  "$(cat /sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_cur_freq 2>/dev/null)"
p max_khz  "$(cat /sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_max_freq 2>/dev/null)"
p boost    "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
p smt      "$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)"
p isolcpus "$(cat /sys/devices/system/cpu/isolated 2>/dev/null)"
p nohz_full "$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null)"
p mit_spectre_v2       "$(cat /sys/devices/system/cpu/vulnerabilities/spectre_v2 2>/dev/null)"
p mit_retbleed         "$(cat /sys/devices/system/cpu/vulnerabilities/retbleed 2>/dev/null)"
p mit_spec_store_bypass "$(cat /sys/devices/system/cpu/vulnerabilities/spec_store_bypass 2>/dev/null)"
d="$(ethtool -i "$IFACE" 2>/dev/null)"
# The JIT state changes the instruction stream that actually runs, so Table I's
# "eBPF JIT enabled" needs a recorded value rather than an assumption. harden
# rewrites constants and would change the code path even with the JIT on.
p bpf_jit_enable "$(cat /proc/sys/net/core/bpf_jit_enable 2>/dev/null)"
p bpf_jit_harden "$(sudo -n cat /proc/sys/net/core/bpf_jit_harden 2>/dev/null)"
p bpf_stats_enabled "$(cat /proc/sys/kernel/bpf_stats_enabled 2>/dev/null)"
# The hard-lockup detector holds one of the six programmable core counters on
# every CPU while it is enabled. run_cell.sh asks for six core events, so with
# the watchdog on perf has to multiplex them and every count becomes an
# extrapolation. The cell-level run-share gate rejects that, but the campaign
# manifest must still record which of the two states the numbers were taken in.
p nmi_watchdog "$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)"
p perf_event_paranoid "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)"
# Captured before any path is installed, so this is the idle default and NOT the
# affinity during a trial. Every native XDP attach resets the mask, and
# run_cell.sh re-pins and re-verifies it per cell, then records the verified
# value in the per-cell state sidecar. That sidecar is authoritative.
q_irq="$(grep -i "${IFACE}-TxRx-0" /proc/interrupts 2>/dev/null | awk -F: '{gsub(/ /,"",$1);print $1;exit}')"
p queue_irq "$q_irq"
p queue_irq_effective_affinity_idle "$(cat /proc/irq/"${q_irq:-none}"/effective_affinity_list 2>/dev/null)"
p nic_driver "$(printf '%s\n' "$d" | awk -F': ' '/^driver/{print $2}')"
p nic_fw     "$(printf '%s\n' "$d" | awk -F': ' '/^firmware-version/{print $2}')"
bus="$(printf '%s\n' "$d" | awk -F': ' '/^bus-info/{print $2}')"
p nic_bus "$bus"
p nic_pcie "$(sudo -n lspci -vv -s "$bus" 2>/dev/null | awk -F'LnkSta:' '/LnkSta:/{gsub(/^[ \t]+/,"",$2);print $2; exit}')"
p combined_queues "$(ethtool -l "$IFACE" 2>/dev/null | awk '/^Current/{f=1} f&&/Combined:/{print $2; exit}')"
p ring_rx "$(ethtool -g "$IFACE" 2>/dev/null | awk '/^Current/{f=1} f&&/^RX:/{print $2; exit}')"
p coalesce_rx_usecs "$(ethtool -c "$IFACE" 2>/dev/null | awk '/rx-usecs:/{print $2; exit}')"
p pause "$(ethtool -a "$IFACE" 2>/dev/null | awk '/RX:/{r=$2} /TX:/{t=$2} END{print r"/"t}')"
p xdp_tools "$(dpkg-query -W -f='${Version}' xdp-tools 2>/dev/null)"
p xdp_bench_sha256 "$(sha256sum "$(command -v xdp-bench)" 2>/dev/null | awk '{print $1}')"
p libxdp "$(dpkg-query -W -f='${Version}' libxdp1 2>/dev/null)"
# Recorded as DuT state, not as a measured path. The audit requires that no
# raw-table rule and no nftables table is active, so the installed backends and
# the loaded x_tables modules belong to the state that has to be checked.
p iptables_default "$(iptables --version 2>/dev/null)"
p iptables_legacy "$(iptables-legacy --version 2>/dev/null)"
p iptables_nft "$(iptables-nft --version 2>/dev/null)"
p nft "$(nft --version 2>/dev/null)"
p xtables_modules "$(for m in x_tables ip_tables iptable_raw; do modinfo -F filename $m >/dev/null 2>&1 && printf '%s ' $m; done)"
p bpftool "$(bpftool version 2>/dev/null | head -1 | sed 's/ features:.*//')"
p bpftrace "$(bpftrace --version 2>/dev/null)"
p perf "$(perf --version 2>/dev/null)"
REMOTE

# ---- tester (local): emit "tester.<key>\t<value>" ----
t(){ printf 'tester.%s\t%s\n' "$1" "$2" >>"$TMP"; }
lnksta(){ (sudo -n lspci -vv -d "$TESTER_NIC" 2>/dev/null || lspci -vv -d "$TESTER_NIC" 2>/dev/null) \
  | awk -F'LnkSta:' '/LnkSta:/{gsub(/^[ \t]+/,"",$2);print $2; exit}'; }
t kernel "$(uname -r)"
t cpu_model "$(awk -F: '/model name/{sub(/^ /,"",$2);print $2; exit}' /proc/cpuinfo)"
t trex_version "$(basename "$TREX_DIR" | sed 's/^v//')"
t x520_bus "$(lspci -d "$TESTER_NIC" 2>/dev/null | awk '{print $1; exit}')"
t x520_driver "$(lspci -k -d "$TESTER_NIC" 2>/dev/null | awk '/in use/{print $NF; exit}')"
t x520_pcie "$(lnksta)"

# ---- assemble JSON ----
python3 - "$TMP" "$TS" <<'PY'
import sys, json
dut={}; tester={}
for line in open(sys.argv[1]):
    line=line.rstrip('\n')
    if '\t' not in line: continue
    k, v = line.split('\t', 1)
    sect, key = k.split('.', 1)
    (dut if sect == 'dut' else tester)[key] = v
print(json.dumps({"captured_utc": sys.argv[2], "dut": dut, "tester": tester}, indent=2))
PY
rm -f "$TMP"
