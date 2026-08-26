#!/usr/bin/env python3
"""Smoke-test traffic driver for the XDP testbed.

Connects to a running TRex server, sends a single fixed 64 B UDP flow at a
requested rate on port 1 (-> DuT) for a fixed duration, then prints the
realized TX stats as JSON. The destination MAC is the DuT's X520 port so the
frames pass the NIC unicast filter without promiscuous mode.

Usage: python3 smoke_stream.py --pps 2000000 --duration 15 --port 1
"""
import argparse
import json
import sys

sys.path.insert(0, "/opt/trex/v3.08/automation/trex_control_plane/interactive")
from trex.stl.api import (  # noqa: E402
    STLClient, STLStream, STLTXCont, STLPktBuilder, Ether, IP, UDP,
)

DUT_MAC = "f8:f2:1e:2b:65:bd"   # DuT enp35s0f1
SRC_MAC = "f8:f2:1e:0a:a8:5d"   # tester enp1s0f1 (TRex port 1)


def build_pkt():
    # 14 (Eth) + 20 (IP) + 8 (UDP) = 42; pad to 60 -> 64 B on wire incl. FCS.
    base = (Ether(dst=DUT_MAC, src=SRC_MAC) /
            IP(src="10.10.10.1", dst="10.10.10.2") /
            # Ports mirror the original XDP evaluation's generator
            # (udp_for_benchmarks.py: dport=12+i, sport=1025), so the reproduced
            # filter rule (-p udp --dport 9:19) matches. A non-matching dport
            # would let packets pass the raw hook and travel up the stack, which
            # silently measures a far more expensive path.
            UDP(sport=1025, dport=12))
    pad = max(0, 60 - len(base))
    return base / ("x" * pad)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pps", type=int, default=2_000_000)
    ap.add_argument("--duration", type=int, default=15)
    ap.add_argument("--port", type=int, default=1)
    args = ap.parse_args()

    c = STLClient(server="127.0.0.1")
    c.connect()
    try:
        c.reset(ports=[args.port])
        stream = STLStream(packet=STLPktBuilder(pkt=build_pkt()),
                           mode=STLTXCont(pps=args.pps))
        c.add_streams([stream], ports=[args.port])
        c.clear_stats()
        c.start(ports=[args.port], mult="1", duration=args.duration)
        c.wait_on_traffic(rx_delay_ms=1000)
        s = c.get_stats()
        p = s[args.port]
        out = {
            "requested_pps": args.pps,
            "duration_s": args.duration,
            "tx_pps_avg": round(p["tx_pps"], 1),
            "tx_pkts": p["opackets"],
            "tx_bps_L1": round(p.get("tx_bps_L1", 0), 1),
            "oerrors": p["oerrors"],
            "port_util_pct": round(p.get("tx_util", 0.0), 2),
        }
        print(json.dumps(out, indent=2))
    finally:
        c.disconnect()


if __name__ == "__main__":
    main()
