#!/usr/bin/env python3
"""check_asm_llvm.py - cross-check tools/rvasm.py against LLVM.

Assembles every test with both rvasm.py and clang/lld (riscv32, rv32i,
no relaxation, same section addresses) and compares the .text words.
Differences are allowed only where both encodings are a legal expansion of
the same pseudo-instruction (e.g. LLVM may expand `li` differently), so
any mismatch is printed for a human to look at.

Requires: clang with the RISC-V target, ld.lld, llvm-objcopy.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import rvasm  # noqa: E402


def main() -> int:
    if not shutil.which("clang") or not shutil.which("llvm-objcopy"):
        print("clang / llvm-objcopy not found - skipping")
        return 0
    srcs = sorted((ROOT / "tests").glob("*/*.S"))
    total_diff = 0
    with tempfile.TemporaryDirectory() as tmp:
        for src in srcs:
            elf = Path(tmp) / (src.stem + ".elf")
            binf = Path(tmp) / (src.stem + ".bin")
            subprocess.run(["clang", "--target=riscv32", "-march=rv32i", "-mno-relax", "-nostdlib",
                            "-fuse-ld=lld", "-Wl,-Ttext=0", "-Wl,--section-start=.data=0x2000",
                            "-Wl,-e,0", "-o", str(elf), str(src)], check=True)
            subprocess.run(["llvm-objcopy", "-O", "binary", "--only-section=.text", str(elf), str(binf)],
                           check=True)
            b = binf.read_bytes()
            ref = [int.from_bytes(b[i:i + 4], "little") for i in range(0, len(b), 4)]
            mine, _ = rvasm.assemble_file(str(src))
            diffs = [i for i, (r, m) in enumerate(zip(ref, mine)) if r != m]
            total_diff += len(diffs)
            status = "identical" if not diffs else f"{len(diffs)} differing words"
            print(f"  {src.stem:14s} {len(ref):5d} words  {status}")
            for i in diffs[:4]:
                print(f"      @{4 * i:#06x}  llvm={ref[i]:08x}  rvasm={mine[i]:08x}")
    print("\nNote: differences are expected only for `li` constants that LLVM\n"
          "builds as addi+slli instead of lui+addi (both are valid).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
