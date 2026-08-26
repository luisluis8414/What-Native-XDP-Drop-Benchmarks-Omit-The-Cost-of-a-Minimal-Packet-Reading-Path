#!/usr/bin/env bash
# Install, verify, count, and clear the measured packet path.
# Runs on the DuT as root.
set -uo pipefail

CMD="${1:-}"
PATH_NAME="${2:-}"
IFACE="${3:-enp35s0f1}"
# Attach mode of the XDP paths. native runs inside the ixgbe driver, skb runs at
# the generic hook after the kernel has built an skb. The mode changes what a
# verification must assert, so it is a parameter and not a constant.
MODE="${4:-native}"

IPT_LEGACY=iptables-legacy
IPT_NFT=iptables-nft

die() { echo "dut_path: $*" >&2; exit 1; }

case "$PATH_NAME" in
  xdp_drop|none|"") ;;
  *) die "unknown configuration: $PATH_NAME" ;;
esac

case "$MODE" in
  native|skb) ;;
  *) die "unknown XDP mode: $MODE" ;;
esac

legacy_rules() {
  $IPT_LEGACY -t raw -S PREROUTING 2>/dev/null | grep -v '^-P ' || true
}

legacy_rule_count() {
  legacy_rules | grep -c . || true
}

iptnft_rule_count() {
  $IPT_NFT -t raw -S PREROUTING 2>/dev/null | grep -v '^-P ' | grep -c . || true
}

nft_table_count() {
  nft list tables 2>/dev/null | grep -c . || true
}

xdp_attached() {
  grep -qE 'xdp(generic)?/id|prog/xdp' <<<"$(ip -d link show dev "$IFACE" 2>/dev/null)"
}

xdp_is_generic() {
  grep -q 'generic' <<<"$(bpftool net show dev "$IFACE" 2>/dev/null)"
}

# The attached mode must be the requested one. A silent fallback to the generic
# hook would answer a different question at the same throughput number.
verify_mode() {
  if [ "$MODE" = skb ]; then
    xdp_is_generic || { echo "FAIL XDP is not attached at the generic hook" >&2; return 1; }
  else
    xdp_is_generic && { echo "FAIL XDP is not in native mode" >&2; return 1; }
  fi
  return 0
}

do_clear() {
  # Clear both attach points explicitly. A generic program does not go away when
  # only the driver hook is cleared, and a leftover would be measured as if it
  # belonged to the next cell.
  ip link set dev "$IFACE" xdpgeneric off 2>/dev/null || true
  ip link set dev "$IFACE" xdpdrv off 2>/dev/null || true
  ip link set dev "$IFACE" xdp off 2>/dev/null || true

  # A raw-table DROP rule left over from any source would silently discard
  # packets before the XDP hook, so clear the unconditional forms here and let
  # do_verify reject anything else.
  while $IPT_LEGACY -t raw -D PREROUTING -j DROP 2>/dev/null; do :; done
  while $IPT_LEGACY -t raw -D PREROUTING -i "$IFACE" -j DROP 2>/dev/null; do :; done
  while $IPT_NFT -t raw -D PREROUTING -j DROP 2>/dev/null; do :; done
}

do_install() {
  case "$PATH_NAME" in
    xdp_drop)
      # xdp-bench is launched by run_cell.sh as a transient unit.
      :
      ;;
    *) die "install needs a configuration" ;;
  esac
}

verify_no_netfilter() {
  local errs=0
  [ "$(legacy_rule_count)" -eq 0 ] || { echo "FAIL a legacy raw rule is active" >&2; errs=1; }
  [ "$(iptnft_rule_count)" -eq 0 ] || { echo "FAIL an iptables-nft raw rule is active" >&2; errs=1; }
  [ "$(nft_table_count)" -eq 0 ] || { echo "FAIL an nftables table is active" >&2; errs=1; }
  return "$errs"
}

do_verify() {
  local errs=0

  case "$PATH_NAME" in
    xdp_drop)
      xdp_attached || { echo "FAIL no XDP program is attached" >&2; errs=1; }
      verify_mode || errs=1
      verify_no_netfilter || errs=1
      ;;
    *) die "verify needs a configuration" ;;
  esac

  grep -q '^nf_conntrack' <<<"$(lsmod 2>/dev/null)" && { echo "FAIL nf_conntrack is loaded" >&2; errs=1; }

  [ "$errs" -eq 0 ] || exit 1
  echo "OK $PATH_NAME ($MODE mode)"
}

# xdp-bench keeps its own per-packet statistics, so the path exposes no rule
# counter of its own.
do_count() {
  echo -1
}

case "$CMD" in
  clear) do_clear ;;
  install) do_install ;;
  verify) do_verify ;;
  count) do_count ;;
  *) die "usage: dut_path.sh <clear|install|verify|count> <configuration> [iface] [native|skb]" ;;
esac
