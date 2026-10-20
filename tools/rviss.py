#!/usr/bin/env python3
"""rviss.py - RV32I instruction-set simulator used as the golden reference.

It executes one instruction at a time with no notion of a pipeline, so any
difference between its commit log and the RTL's commit log points at a
pipeline bug (missing forward, wrong stall, bad flush, ...).

Commit log format (identical to tb/tb_top.sv):
    <pc> <insn> [x<rd>=<value>] [st<size> <addr>=<value>]

Usage:
  rviss.py prog.hex [--trace commit.log] [--max-steps N]
"""

from __future__ import annotations

import argparse
import sys

MEM_BYTES = 64 * 1024
MASK32 = 0xFFFFFFFF


def sext(v: int, bits: int) -> int:
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v: int) -> int:
    return sext(v, 32)


class ISS:
    def __init__(self, words: list[int]):
        self.mem = bytearray(MEM_BYTES)
        for i, w in enumerate(words):
            self.mem[4 * i:4 * i + 4] = w.to_bytes(4, "little")
        # Instruction memory is a separate, read-only copy (Harvard), the
        # same as the RTL testbench.
        self.imem = bytes(self.mem)
        self.x = [0] * 32
        self.pc = 0
        self.halted = False
        self.instret = 0
        self.log: list[str] = []

    # Memory addresses wrap at 64 KiB, matching the RTL memories.
    def _a(self, addr: int) -> int:
        return addr & (MEM_BYTES - 1)

    def load(self, addr: int, size: int, signed: bool) -> int:
        a = self._a(addr)
        v = int.from_bytes(self.mem[a:a + size], "little")
        return sext(v, 8 * size) & MASK32 if signed else v

    def store(self, addr: int, size: int, val: int) -> None:
        a = self._a(addr)
        self.mem[a:a + size] = (val & ((1 << (8 * size)) - 1)).to_bytes(size, "little")

    def fetch(self, pc: int) -> int:
        a = self._a(pc)
        return int.from_bytes(self.imem[a:a + 4], "little")

    def step(self) -> None:
        pc = self.pc
        insn = self.fetch(pc)
        op = insn & 0x7F
        rd = (insn >> 7) & 0x1F
        f3 = (insn >> 12) & 7
        rs1 = (insn >> 15) & 0x1F
        rs2 = (insn >> 20) & 0x1F
        f7 = insn >> 25
        a, b = self.x[rs1], self.x[rs2]

        imm_i = sext(insn >> 20, 12)
        imm_s = sext(((insn >> 25) << 5) | ((insn >> 7) & 0x1F), 12)
        imm_b = sext((((insn >> 31) & 1) << 12) | (((insn >> 7) & 1) << 11)
                     | (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1), 13)
        imm_u = insn & 0xFFFFF000
        imm_j = sext((((insn >> 31) & 1) << 20) | (((insn >> 12) & 0xFF) << 12)
                     | (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1), 21)

        next_pc = (pc + 4) & MASK32
        wr = None       # value written to rd
        st = None       # (size, addr, value)

        if op == 0x37:                                  # LUI
            wr = imm_u
        elif op == 0x17:                                # AUIPC
            wr = (pc + imm_u) & MASK32
        elif op == 0x6F:                                # JAL
            wr = next_pc
            next_pc = (pc + imm_j) & MASK32
        elif op == 0x67:                                # JALR
            wr = next_pc
            next_pc = (a + imm_i) & MASK32 & ~1
        elif op == 0x63:                                # branches
            taken = {
                0: a == b, 1: a != b,
                4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                6: a < b, 7: a >= b,
            }.get(f3, False)
            if taken:
                next_pc = (pc + imm_b) & MASK32
        elif op == 0x03:                                # loads
            addr = (a + imm_i) & MASK32
            size = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}.get(f3, 4)
            wr = self.load(addr, size, signed=f3 in (0, 1))
        elif op == 0x23:                                # stores
            addr = (a + imm_s) & MASK32
            size = {0: 1, 1: 2}.get(f3 & 3, 4)
            val = b & ((1 << (8 * size)) - 1)
            self.store(addr, size, val)
            st = (size, addr, val)
        elif op in (0x13, 0x33):                        # ALU
            is_reg = op == 0x33
            y = b if is_reg else imm_i & MASK32
            sh = y & 0x1F
            alt = (f7 >> 5) & 1
            if f3 == 0:
                r = a - y if (is_reg and alt) else a + y
            elif f3 == 1:
                r = a << sh
            elif f3 == 2:
                r = int(s32(a) < s32(y))
            elif f3 == 3:
                r = int(a < (y & MASK32))
            elif f3 == 4:
                r = a ^ y
            elif f3 == 5:
                r = (s32(a) >> sh) if alt else (a >> sh)
            elif f3 == 6:
                r = a | y
            else:
                r = a & y
            wr = r & MASK32
        elif op == 0x73 and f3 == 0:                    # ECALL / EBREAK
            self.halted = True
        # FENCE and unknown encodings: NOP

        line = f"{pc:08x} {insn:08x}"
        if wr is not None and rd != 0:
            self.x[rd] = wr & MASK32
            line += f" x{rd}={wr & MASK32:08x}"
        if st is not None:
            line += f" st{st[0]} {st[1]:08x}={st[2]:08x}"
        self.log.append(line)
        self.instret += 1
        self.pc = next_pc

    def run(self, max_steps: int = 2_000_000) -> bool:
        while not self.halted and self.instret < max_steps:
            self.step()
        return self.halted


def read_hex(path: str) -> list[int]:
    with open(path) as f:
        return [int(t, 16) for t in f.read().split() if not t.startswith("//")]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hex")
    ap.add_argument("--trace")
    ap.add_argument("--max-steps", type=int, default=2_000_000)
    args = ap.parse_args()

    iss = ISS(read_hex(args.hex))
    ok = iss.run(args.max_steps)
    if args.trace:
        with open(args.trace, "w") as f:
            f.write("\n".join(iss.log) + "\n")
    if not ok:
        print(f"TIMEOUT after {iss.instret} instructions")
        return 2
    print("PASS" if iss.x[10] == 0 else f"FAIL (a0={iss.x[10]})", f"instret={iss.instret}")
    return 0 if iss.x[10] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
