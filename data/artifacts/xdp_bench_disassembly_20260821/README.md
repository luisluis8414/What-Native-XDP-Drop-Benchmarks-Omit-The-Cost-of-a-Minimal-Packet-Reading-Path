# xdp-bench program disassembly

This directory records the eBPF and x86-64 JIT code loaded for the two
`xdp-bench drop` variants used in the paper.

## Provenance

- Capture date: 2026-08-21
- DUT: AMD Ryzen 5 1600 running Linux `7.0.0-22-generic`
- Installed package: Ubuntu `xdp-tools` `1.6.2-1ubuntu1`
- Installed `/usr/sbin/xdp-bench` SHA-256:
  `024fce683536f26c227cbc0666737a38346ba672fe9bda72b056625bd1f9e372`
- Upstream tag: `v1.6.2`
- Upstream commit:
  `c4d4bf87c6317d9fa5442927527c51b795c82ec5`
- Ubuntu patch commit:
  `a107e27e9b1b31dab7dd1b6f896c8596a5127ead`
- `bpftool`: 7.7.0 using libbpf 1.7
- GNU `objdump`: 2.46

The Ubuntu patch adds `limits.h` only to `xdp-dump/xdpdump.c`. It does not
change `xdp-bench` or either program recorded here. The package changelog names
this downstream change as `debian/patches/563.patch`.

## Capture method

Each variant was loaded separately with native XDP mode on `enp35s0f1`.
`bpftool prog dump xlated` produced the eBPF disassembly. The installed
`bpftool` lacks JIT disassembly support, so a small BPF system-call helper read
the JIT image through `BPF_OBJ_GET_INFO_BY_FD`. GNU `objdump` then decoded the
image as x86-64 machine code. The helper source is archived as
`dump_bpf_jit.c`.

The eBPF count is the translated byte length divided by the eight-byte size of
one `struct bpf_insn` slot. The x86-64 count includes every instruction in the
JIT image, including its prologue and epilogue.

| Variant | eBPF slots | eBPF bytes | x86-64 instructions | JIT bytes |
| --- | ---: | ---: | ---: | ---: |
| `no-touch` | 38 | 304 | 48 | 180 |
| `read-data` | 51 | 408 | 68 | 238 |
| Added by `read-data` | 13 | 104 | 20 | 58 |

`no-touch.txt` and `read-data.txt` contain the complete program metadata,
translated eBPF instructions, native JIT instructions, and raw JIT image hash.
