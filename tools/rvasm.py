#!/usr/bin/env python3
"""rvasm.py - a small two-pass RV32I assembler.

Produces a $readmemh image (one little-endian 32-bit word per line, starting
at address 0) so the project needs no RISC-V cross toolchain.

Supported:
  * every RV32I base instruction (incl. FENCE, ECALL, EBREAK)
  * pseudo-instructions: nop li la mv not neg seqz snez sltz sgtz
    j jr jal(1-arg) jalr(1-arg) ret call beqz bnez blez bgez bltz bgtz
    bgt ble bgtu bleu
  * directives: .text .data .org .align .word .half .byte .space .zero
    .globl/.global/.section (ignored), .equ/.set
  * labels, numeric literals (dec/hex/bin/char), ABI register names,
    %hi(sym) / %lo(sym) relocations, simple +/- expressions

Usage:
  rvasm.py prog.S -o prog.hex [--data-base 0x2000]
"""

from __future__ import annotations

import argparse
import re
import sys

REGS = {f"x{i}": i for i in range(32)}
ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
       "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
       "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
       "t3", "t4", "t5", "t6"]
REGS.update({n: i for i, n in enumerate(ABI)})
REGS["fp"] = 8

R_TYPE = {  # name: (funct7, funct3)
    "add": (0x00, 0), "sub": (0x20, 0), "sll": (0x00, 1), "slt": (0x00, 2),
    "sltu": (0x00, 3), "xor": (0x00, 4), "srl": (0x00, 5), "sra": (0x20, 5),
    "or": (0x00, 6), "and": (0x00, 7),
}
I_ALU = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
I_SHIFT = {"slli": (0x00, 1), "srli": (0x00, 5), "srai": (0x20, 5)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


class AsmError(Exception):
    pass


def fits_signed(v: int, bits: int) -> bool:
    return -(1 << (bits - 1)) <= v < (1 << (bits - 1))


def to_s32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def hi20(v: int) -> int:
    """Upper 20 bits, rounded so that hi<<12 + sext(lo12) == v."""
    return ((v + 0x800) >> 12) & 0xFFFFF


def lo12(v: int) -> int:
    lo = v & 0xFFF
    return lo - 0x1000 if lo & 0x800 else lo


class Assembler:
    def __init__(self, data_base: int = 0x2000):
        self.data_base = data_base
        self.symbols: dict[str, int] = {}
        # GNU-style numeric local labels: "1:" defined many times,
        # referenced as "1f" (next definition) or "1b" (previous one).
        self.local_defs: dict[str, list[int]] = {}
        self.local_seen: dict[str, int] = {}
        self.mem: dict[int, int] = {}  # byte address -> byte

    # ------------------------------------------------------------------ parsing
    @staticmethod
    def strip_comment(line: str) -> str:
        out, in_char = [], False
        for i, ch in enumerate(line):
            if ch == "'" :
                in_char = not in_char
            if not in_char and (ch == "#" or (ch == "/" and line[i:i + 2] == "//") or ch == ";"):
                break
            out.append(ch)
        return "".join(out).strip()

    @staticmethod
    def split_operands(s: str) -> list[str]:
        return [p.strip() for p in s.split(",")] if s.strip() else []

    def reg(self, tok: str) -> int:
        t = tok.strip().lower()
        if t not in REGS:
            raise AsmError(f"bad register '{tok}'")
        return REGS[t]

    def value(self, expr: str, final: bool) -> int:
        """Evaluate a literal / symbol / %hi / %lo / +- expression."""
        e = expr.strip()
        if re.fullmatch(r"'.'", e):  # character literal (may be ' ')
            return ord(e[1])
        m = re.fullmatch(r"%(hi|lo)\((.+)\)", e)
        if m:
            v = self.value(m.group(2), final)
            return hi20(v) if m.group(1) == "hi" else lo12(v)
        # tokenise on + and - (keeping a leading sign)
        terms = re.findall(r"[+-]?\s*[^+-]+", e)
        if not terms:
            raise AsmError(f"bad expression '{expr}'")
        total = 0
        for term in terms:
            term = term.replace(" ", "")
            sign = -1 if term.startswith("-") else 1
            term = term.lstrip("+-")
            total += sign * self.atom(term, final)
        return total

    def atom(self, t: str, final: bool) -> int:
        if re.fullmatch(r"'.'", t):
            return ord(t[1])
        if re.fullmatch(r"0[xX][0-9a-fA-F_]+", t):
            return int(t.replace("_", ""), 16)
        if re.fullmatch(r"0[bB][01_]+", t):
            return int(t.replace("_", ""), 2)
        m = re.fullmatch(r"([0-9]+)([fb])", t)
        if m:
            n, d = m.groups()
            seen = self.local_seen.get(n, 0)
            defs = self.local_defs.get(n, [])
            idx = seen if d == "f" else seen - 1
            if 0 <= idx < len(defs):
                return defs[idx]
            if final:
                raise AsmError(f"no local label for '{t}'")
            return 0
        if re.fullmatch(r"[0-9]+", t):
            return int(t)
        if re.fullmatch(r"[A-Za-z_.$][\w.$]*", t):
            if t in self.symbols:
                return self.symbols[t]
            if final:
                raise AsmError(f"undefined symbol '{t}'")
            return 0
        raise AsmError(f"bad literal '{t}'")

    def mem_operand(self, tok: str, final: bool) -> tuple[int, int]:
        m = re.fullmatch(r"(.*)\((\s*\w+\s*)\)", tok.strip())
        if not m:
            raise AsmError(f"expected offset(reg), got '{tok}'")
        off = self.value(m.group(1), final) if m.group(1).strip() else 0
        return off, self.reg(m.group(2))

    # ---------------------------------------------------------------- encoding
    @staticmethod
    def enc_r(f7, rs2, rs1, f3, rd, op):
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    @staticmethod
    def enc_i(imm, rs1, f3, rd, op):
        if not fits_signed(imm, 12):
            raise AsmError(f"I-immediate {imm} out of range")
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    @staticmethod
    def enc_s(imm, rs2, rs1, f3, op):
        if not fits_signed(imm, 12):
            raise AsmError(f"S-immediate {imm} out of range")
        imm &= 0xFFF
        return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op

    @staticmethod
    def enc_b(off, rs2, rs1, f3):
        if off & 1 or not fits_signed(off, 13):
            raise AsmError(f"branch offset {off} out of range / misaligned")
        o = off & 0x1FFF
        return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) \
            | (f3 << 12) | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63

    @staticmethod
    def enc_u(imm20, rd, op):
        return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

    @staticmethod
    def enc_j(off, rd):
        if off & 1 or not fits_signed(off, 21):
            raise AsmError(f"jump offset {off} out of range / misaligned")
        o = off & 0x1FFFFF
        return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) \
            | (((o >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

    # ---------------------------------------------------- instruction expansion
    def li_words(self, rd: int, imm: int) -> list[int]:
        imm = to_s32(imm)
        if fits_signed(imm, 12):
            return [self.enc_i(imm, 0, 0, rd, 0x13)]
        words = [self.enc_u(hi20(imm), rd, 0x37)]
        if lo12(imm) != 0:
            words.append(self.enc_i(lo12(imm), rd, 0, rd, 0x13))
        return words

    def li_size(self, ops: list[str]) -> int:
        """li must have a fixed size in pass 1; symbols are not allowed."""
        imm = to_s32(self.value(ops[1], final=False))
        if fits_signed(imm, 12):
            return 4
        return 4 if lo12(imm) == 0 else 8

    def expand(self, mn: str, ops: list[str], pc: int, final: bool) -> list[int]:
        V = lambda s: self.value(s, final)  # noqa: E731
        R = self.reg

        # ---- pseudo-instructions
        if mn == "nop":
            return [0x00000013]
        if mn == "li":
            return self.li_words(R(ops[0]), V(ops[1]))
        if mn == "la":
            off = to_s32(V(ops[1]) - pc)
            rd = R(ops[0])
            return [self.enc_u(hi20(off), rd, 0x17), self.enc_i(lo12(off), rd, 0, rd, 0x13)]
        if mn == "call":
            off = to_s32(V(ops[0]) - pc)
            return [self.enc_u(hi20(off), 1, 0x17), self.enc_i(lo12(off), 1, 0, 1, 0x67)]
        if mn == "mv":
            return [self.enc_i(0, R(ops[1]), 0, R(ops[0]), 0x13)]
        if mn == "not":
            return [self.enc_i(-1, R(ops[1]), 4, R(ops[0]), 0x13)]
        if mn == "neg":
            return [self.enc_r(0x20, R(ops[1]), 0, 0, R(ops[0]), 0x33)]
        if mn == "seqz":
            return [self.enc_i(1, R(ops[1]), 3, R(ops[0]), 0x13)]
        if mn == "snez":
            return [self.enc_r(0, R(ops[1]), 0, 3, R(ops[0]), 0x33)]
        if mn == "sltz":
            return [self.enc_r(0, 0, R(ops[1]), 2, R(ops[0]), 0x33)]
        if mn == "sgtz":
            return [self.enc_r(0, R(ops[1]), 0, 2, R(ops[0]), 0x33)]
        if mn == "j":
            return [self.enc_j(V(ops[0]) - pc, 0)]
        if mn == "jal" and len(ops) == 1:
            return [self.enc_j(V(ops[0]) - pc, 1)]
        if mn == "jr":
            return [self.enc_i(0, R(ops[0]), 0, 0, 0x67)]
        if mn == "jalr" and len(ops) == 1:
            return [self.enc_i(0, R(ops[0]), 0, 1, 0x67)]
        if mn == "ret":
            return [self.enc_i(0, 1, 0, 0, 0x67)]
        zbr = {"beqz": ("beq", False), "bnez": ("bne", False), "bltz": ("blt", False),
               "bgez": ("bge", False), "blez": ("bge", True), "bgtz": ("blt", True)}
        if mn in zbr:
            base, swap = zbr[mn]
            rs = R(ops[0])
            a, b = (0, rs) if swap else (rs, 0)
            return [self.enc_b(V(ops[1]) - pc, b, a, BRANCHES[base])]
        swapped = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}
        if mn in swapped:
            return [self.enc_b(V(ops[2]) - pc, R(ops[0]), R(ops[1]), BRANCHES[swapped[mn]])]

        # ---- base ISA
        if mn in R_TYPE:
            f7, f3 = R_TYPE[mn]
            return [self.enc_r(f7, R(ops[2]), R(ops[1]), f3, R(ops[0]), 0x33)]
        if mn in I_ALU:
            return [self.enc_i(V(ops[2]), R(ops[1]), I_ALU[mn], R(ops[0]), 0x13)]
        if mn in I_SHIFT:
            f7, f3 = I_SHIFT[mn]
            sh = V(ops[2])
            if not 0 <= sh < 32:
                raise AsmError(f"shift amount {sh} out of range")
            return [(f7 << 25) | (sh << 20) | (R(ops[1]) << 15) | (f3 << 12) | (R(ops[0]) << 7) | 0x13]
        if mn in LOADS:
            off, rs1 = self.mem_operand(ops[1], final)
            return [self.enc_i(off, rs1, LOADS[mn], R(ops[0]), 0x03)]
        if mn in STORES:
            off, rs1 = self.mem_operand(ops[1], final)
            return [self.enc_s(off, R(ops[0]), rs1, STORES[mn], 0x23)]
        if mn in BRANCHES:
            return [self.enc_b(V(ops[2]) - pc, R(ops[1]), R(ops[0]), BRANCHES[mn])]
        if mn == "lui":
            return [self.enc_u(V(ops[1]), R(ops[0]), 0x37)]
        if mn == "auipc":
            return [self.enc_u(V(ops[1]), R(ops[0]), 0x17)]
        if mn == "jal":
            return [self.enc_j(V(ops[1]) - pc, R(ops[0]))]
        if mn == "jalr":
            if len(ops) == 2:  # jalr rd, off(rs1)
                off, rs1 = self.mem_operand(ops[1], final)
            else:              # jalr rd, rs1, off
                rs1, off = R(ops[1]), V(ops[2])
            return [self.enc_i(off, rs1, 0, R(ops[0]), 0x67)]
        if mn == "fence":
            return [0x0FF0000F]
        if mn == "ecall":
            return [0x00000073]
        if mn == "ebreak":
            return [0x00100073]
        raise AsmError(f"unknown instruction '{mn}'")

    def size_of(self, mn: str, ops: list[str]) -> int:
        if mn == "li":
            return self.li_size(ops)
        if mn in ("la", "call"):
            return 8
        return 4

    # ------------------------------------------------------------------ driver
    def assemble(self, text: str) -> None:
        lines = text.splitlines()
        for final in (False, True):
            self.local_seen = {}
            sections = {"text": 0, "data": self.data_base}
            cur = "text"
            for lineno, raw in enumerate(lines, 1):
                try:
                    cur = self._line(raw, sections, cur, final)
                except AsmError as e:
                    raise AsmError(f"line {lineno}: {e}\n    {raw.strip()}") from None

    def _emit(self, addr: int, data: bytes, final: bool) -> None:
        if not final:
            return
        for i, b in enumerate(data):
            if addr + i in self.mem:
                raise AsmError(f"address {addr + i:#x} written twice (overlapping sections?)")
            self.mem[addr + i] = b

    def _line(self, raw: str, sections: dict, cur: str, final: bool) -> str:
        line = self.strip_comment(raw)
        # labels (possibly several on one line)
        while True:
            m = re.match(r"^([A-Za-z_.$][\w.$]*|[0-9]+)\s*:(.*)$", line)
            if not m:
                break
            name = m.group(1)
            if name.isdigit():
                if not final:
                    self.local_defs.setdefault(name, []).append(sections[cur])
                self.local_seen[name] = self.local_seen.get(name, 0) + 1
                line = m.group(2).strip()
                continue
            if not final:
                if name in self.symbols:
                    raise AsmError(f"duplicate label '{name}'")
                self.symbols[name] = sections[cur]
            line = m.group(2).strip()
        if not line:
            return cur

        parts = line.split(None, 1)
        mn = parts[0].lower()
        rest = parts[1] if len(parts) > 1 else ""
        pc = sections[cur]

        if mn.startswith("."):
            ops = self.split_operands(rest)
            if mn == ".text":
                return "text"
            if mn == ".data":
                return "data"
            if mn in (".globl", ".global", ".section", ".type", ".size", ".option", ".file"):
                return cur
            if mn in (".equ", ".set"):
                if not final:
                    self.symbols[ops[0]] = self.value(ops[1], final=True)
                return cur
            if mn == ".org":
                sections[cur] = self.value(ops[0], final=True)
                return cur
            if mn == ".align":  # power-of-two alignment, like GNU as on RISC-V
                a = 1 << self.value(ops[0], final=True)
                pad = (-pc) % a
                filler = b"\x13\x00\x00\x00" if cur == "text" else b"\x00" * 4
                self._emit(pc, (filler * (pad // 4 + 1))[:pad], final)
                sections[cur] = pc + pad
                return cur
            size = {".word": 4, ".half": 2, ".byte": 1}.get(mn)
            if size:
                for i, op in enumerate(ops):
                    v = self.value(op, final) & ((1 << (8 * size)) - 1)
                    self._emit(pc + i * size, v.to_bytes(size, "little"), final)
                sections[cur] = pc + size * len(ops)
                return cur
            if mn in (".space", ".zero"):
                n = self.value(ops[0], final=True)
                self._emit(pc, bytes(n), final)
                sections[cur] = pc + n
                return cur
            raise AsmError(f"unknown directive '{mn}'")

        ops = self.split_operands(rest)
        if final:
            words = self.expand(mn, ops, pc, final=True)
            if len(words) * 4 != self.size_of(mn, ops):
                raise AsmError("internal: instruction size changed between passes")
            for i, w in enumerate(words):
                self._emit(pc + 4 * i, w.to_bytes(4, "little"), final)
        else:
            if pc % 4:
                raise AsmError("instruction is not word aligned")
            self.expand(mn, ops, pc, final=False)  # validate syntax early
        sections[cur] = pc + self.size_of(mn, ops)
        return cur

    def image_words(self) -> list[int]:
        if not self.mem:
            return []
        top = (max(self.mem) // 4) + 1
        return [int.from_bytes(bytes(self.mem.get(4 * w + i, 0) for i in range(4)), "little")
                for w in range(top)]


def assemble_file(path: str, data_base: int = 0x2000) -> tuple[list[int], dict[str, int]]:
    asm = Assembler(data_base)
    with open(path) as f:
        asm.assemble(f.read())
    return asm.image_words(), asm.symbols


def write_hex(words: list[int], path: str) -> None:
    with open(path, "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--data-base", type=lambda s: int(s, 0), default=0x2000)
    args = ap.parse_args()
    try:
        words, _ = assemble_file(args.src, args.data_base)
    except AsmError as e:
        print(f"{args.src}: {e}", file=sys.stderr)
        return 1
    write_hex(words, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
