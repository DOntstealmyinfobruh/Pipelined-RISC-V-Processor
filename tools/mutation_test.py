#!/usr/bin/env python3
"""mutation_test.py - checks that the test suite actually catches bugs.

Each mutant injects one realistic hazard-handling bug into a copy of the
RTL, rebuilds the forwarding-enabled simulator, and runs the regression.
A mutant is "killed" if at least one test fails. Every mutant should be
killed; a survivor means the tests have a blind spot.

Usage:
  mutation_test.py [--random 50]
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (name, file, original text, mutated text)
MUTANTS = [
    ("no EX/MEM forwarding", "rtl/forwarding_unit.sv",
     "else if (exmem_reg_write && exmem_rd == rs)\n      return FWD_EXMEM;",
     "else if (1'b0)\n      return FWD_EXMEM;"),
    ("no MEM/WB forwarding", "rtl/forwarding_unit.sv",
     "else if (memwb_reg_write && memwb_rd == rs)\n      return FWD_MEMWB;",
     "else if (1'b0)\n      return FWD_MEMWB;"),
    ("wrong forwarding priority (MEM/WB before EX/MEM)", "rtl/forwarding_unit.sv",
     "else if (exmem_reg_write && exmem_rd == rs)\n      return FWD_EXMEM;\n"
     "    else if (memwb_reg_write && memwb_rd == rs)\n      return FWD_MEMWB;",
     "else if (memwb_reg_write && memwb_rd == rs)\n      return FWD_MEMWB;\n"
     "    else if (exmem_reg_write && exmem_rd == rs)\n      return FWD_EXMEM;"),
    ("x0 gets forwarded", "rtl/forwarding_unit.sv",
     "if (!FORWARD_EN || rs == 5'd0)", "if (!FORWARD_EN)"),
    ("no load-use stall", "rtl/hazard_unit.sv",
     "assign load_use = id_valid && ex_mem_read && dep_ex;",
     "assign load_use = 1'b0;"),
    ("load-use ignores rs2", "rtl/hazard_unit.sv",
     "((id_uses_rs1 && id_rs1 == rd) || (id_uses_rs2 && id_rs2 == rd))",
     "(id_uses_rs1 && id_rs1 == rd)"),
    ("store data not forwarded", "rtl/core.sv",
     "store_val: ex_rs2_val", "store_val: id_ex.rs2_val"),
    ("branch compares unforwarded operands", "rtl/core.sv",
     ".a      (ex_rs1_val),\n    .b      (ex_rs2_val),",
     ".a      (id_ex.rs1_val),\n    .b      (id_ex.rs2_val),"),
    ("no flush of IF/ID on taken branch", "rtl/core.sv",
     "if (rst || flush || halt_seen) begin\n      if_id <=",
     "if (rst || halt_seen) begin\n      if_id <="),
    ("no flush of ID/EX on taken branch", "rtl/core.sv",
     "if (rst || flush || stall || !if_id.valid) begin",
     "if (rst || stall || !if_id.valid) begin"),
    ("JALR target not forwarded", "rtl/core.sv",
     "ex_target = (ex_rs1_val + id_ex.imm) & ~32'd1;",
     "ex_target = (id_ex.rs1_val + id_ex.imm) & ~32'd1;"),
    ("no register-file write-through", "rtl/regfile.sv",
     "else if (we && waddr == raddr1)      rdata1 = wdata;",
     "else if (1'b0)                       rdata1 = wdata;"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--random", type=int, default=50)
    args = ap.parse_args()

    survivors = []
    for name, rel, orig, mut in MUTANTS:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / "repo"
            shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns("build", ".git"))
            f = work / rel
            text = f.read_text()
            if orig not in text:
                print(f"  ?? {name}: pattern not found in {rel} (update this script)")
                survivors.append(name)
                continue
            f.write_text(text.replace(orig, mut, 1))
            build = subprocess.run(["make", "-C", str(work), "sim"], capture_output=True, text=True)
            if build.returncode != 0:
                print(f"  ?? {name}: mutant did not build")
                survivors.append(name)
                continue
            run = subprocess.run([sys.executable, str(work / "tools" / "run_tests.py"),
                                  "--random", str(args.random)], capture_output=True, text=True)
            fails = [ln.strip() for ln in run.stdout.splitlines() if ln.strip().startswith("FAIL")]
            fails = [ln for ln in fails if "forward=1" in ln]
            if run.returncode != 0 and fails:
                print(f"  killed   {name:48s} ({len(fails)} failing runs, e.g. {fails[0].split(':')[0][5:]})")
            else:
                print(f"  SURVIVED {name}")
                survivors.append(name)

    print(f"\n{len(MUTANTS) - len(survivors)}/{len(MUTANTS)} mutants killed")
    return 0 if not survivors else 1


if __name__ == "__main__":
    sys.exit(main())
