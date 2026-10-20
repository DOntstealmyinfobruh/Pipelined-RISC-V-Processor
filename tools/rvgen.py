#!/usr/bin/env python3
"""rvgen.py - constrained-random RV32I program generator.

Programs are built to hit pipeline hazards as often as possible:
  * source registers are biased toward the most recently written ones, so
    back-to-back and distance-2 dependencies (forwarding paths) are common;
  * loads are frequently followed by a consumer (load-use stalls);
  * forward branches, JAL and JALR land 1-4 instructions ahead, so their
    flush shadows contain real instructions (including loads and stores)
    that must be squashed;
  * small counted loops exercise taken backward branches.

Every program terminates. Correctness is not self-checked here: the runner
compares the RTL commit log against the golden model's.

Reserved registers:  t6 (x31) data pointer, t5 (x30) loop counter,
                     t4 (x29) JALR scratch. Everything else is fair game.

Usage:
  rvgen.py --seed 7 --length 300 -o rand7.S
"""

from __future__ import annotations

import argparse
import random

DATA_BASE = 0x3000
DATA_BYTES = 256
POOL = [f"x{i}" for i in range(1, 29)]  # x1..x28

R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_OPS = ["slli", "srli", "srai"]
LOADS = {"lb": 1, "lh": 2, "lw": 4, "lbu": 1, "lhu": 2}
STORES = {"sb": 1, "sh": 2, "sw": 4}
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]


class Gen:
    def __init__(self, seed: int):
        self.rng = random.Random(seed)
        self.lines: list[str] = []
        self.recent: list[str] = []  # most recently written registers
        self.label_id = 0

    # ------------------------------------------------------------- helpers
    def label(self) -> str:
        self.label_id += 1
        return f"L{self.label_id}"

    def emit(self, s: str) -> None:
        self.lines.append("    " + s)

    def wrote(self, rd: str) -> None:
        if rd != "x0":
            self.recent = ([rd] + [r for r in self.recent if r != rd])[:4]

    def src(self) -> str:
        r = self.rng.random()
        if self.recent and r < 0.65:
            # weight the very latest producer most (EX/MEM path)
            idx = min(int(self.rng.expovariate(1.2)), len(self.recent) - 1)
            return self.recent[idx]
        if r < 0.70:
            return "x0"
        return self.rng.choice(POOL)

    def dst(self) -> str:
        if self.rng.random() < 0.03:
            return "x0"  # writes to x0 must be ignored (and never forwarded)
        if self.recent and self.rng.random() < 0.2:
            return self.rng.choice(self.recent)  # WAW / overwrite chains
        return self.rng.choice(POOL)

    def imm12(self) -> int:
        return self.rng.choice([
            self.rng.randint(-2048, 2047),
            self.rng.randint(-16, 16),
            self.rng.choice([-2048, -1, 0, 1, 2047]),
        ])

    # -------------------------------------------------------- instructions
    def alu(self) -> None:
        k = self.rng.random()
        rd = self.dst()
        if k < 0.45:
            self.emit(f"{self.rng.choice(R_OPS)} {rd}, {self.src()}, {self.src()}")
        elif k < 0.80:
            self.emit(f"{self.rng.choice(I_OPS)} {rd}, {self.src()}, {self.imm12()}")
        elif k < 0.93:
            self.emit(f"{self.rng.choice(SH_OPS)} {rd}, {self.src()}, {self.rng.randint(0, 31)}")
        elif k < 0.97:
            self.emit(f"lui {rd}, {self.rng.randint(0, 0xFFFFF)}")
        else:
            self.emit(f"auipc {rd}, {self.rng.randint(0, 0xFFFFF)}")
        self.wrote(rd)

    def load(self) -> None:
        op = self.rng.choice(list(LOADS))
        size = LOADS[op]
        off = self.rng.randrange(0, DATA_BYTES, size)
        rd = self.dst()
        self.emit(f"{op} {rd}, {off}(t6)")
        self.wrote(rd)
        if self.rng.random() < 0.6:  # immediate consumer -> load-use stall
            self.alu_using(rd)

    def alu_using(self, reg: str) -> None:
        rd = self.dst()
        other = self.src()
        if self.rng.random() < 0.5:
            self.emit(f"add {rd}, {reg}, {other}")
        else:
            self.emit(f"xor {rd}, {other}, {reg}")
        self.wrote(rd)

    def store(self) -> None:
        op = self.rng.choice(list(STORES))
        size = STORES[op]
        off = self.rng.randrange(0, DATA_BYTES, size)
        self.emit(f"{op} {self.src()}, {off}(t6)")

    def straight(self) -> None:
        """One non-control-flow instruction."""
        k = self.rng.random()
        if k < 0.60:
            self.alu()
        elif k < 0.82:
            self.load()
        else:
            self.store()

    def shadow(self, n: int) -> None:
        for _ in range(n):
            self.straight()

    def branch(self) -> None:
        lab = self.label()
        self.emit(f"{self.rng.choice(BRANCHES)} {self.src()}, {self.src()}, {lab}")
        self.shadow(self.rng.randint(0, 4))
        self.lines.append(f"{lab}:")

    def jal(self) -> None:
        lab = self.label()
        rd = self.rng.choice(["x0", "ra", self.dst()])
        self.emit(f"jal {rd}, {lab}")
        self.shadow(self.rng.randint(0, 3))
        self.lines.append(f"{lab}:")
        self.wrote(rd)

    def jalr(self) -> None:
        lab = self.label()
        rd = self.rng.choice(["x0", "ra", self.dst()])
        self.emit(f"la t4, {lab}")
        self.emit(f"jalr {rd}, 0(t4)")
        self.shadow(self.rng.randint(0, 3))
        self.lines.append(f"{lab}:")
        self.wrote(rd)

    def loop(self) -> None:
        lab = self.label()
        self.emit(f"li t5, {self.rng.randint(1, 5)}")
        self.lines.append(f"{lab}:")
        for _ in range(self.rng.randint(2, 6)):
            if self.rng.random() < 0.15:
                self.branch()
            else:
                self.straight()
        self.emit("addi t5, t5, -1")
        self.emit(f"bnez t5, {lab}")

    # -------------------------------------------------------------- driver
    def program(self, length: int) -> str:
        self.lines = [
            "# auto-generated by tools/rvgen.py - do not edit",
            "    .text",
            "_start:",
        ]
        self.emit(f"li t6, {DATA_BASE:#x}")
        for r in POOL:
            self.emit(f"li {r}, {self.rng.randint(-(1 << 31), (1 << 31) - 1)}")
        # seed the data region so loads return interesting values
        for off in range(0, DATA_BYTES, 4):
            if self.rng.random() < 0.5:
                self.emit(f"sw {self.rng.choice(POOL)}, {off}(t6)")

        weights = [("straight", 70), ("branch", 12), ("jal", 5), ("jalr", 5), ("loop", 8)]
        names = [w[0] for w in weights]
        probs = [w[1] for w in weights]
        start = len(self.lines)
        while len(self.lines) - start < length:
            getattr(self, self.rng.choices(names, probs)[0])()

        self.emit("li a0, 0")
        self.emit("ecall")
        return "\n".join(self.lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--length", type=int, default=300)
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()
    with open(args.output, "w") as f:
        f.write(Gen(args.seed).program(args.length))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
