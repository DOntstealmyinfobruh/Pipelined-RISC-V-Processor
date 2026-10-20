#!/usr/bin/env python3
"""pipeview.py - text pipeline diagram from a simulation VCD.

Reads the per-stage debug signals dumped by the core and prints which
instruction occupies each stage on every cycle, plus stall / flush and the
forwarding-mux selects, e.g.

  cyc  IF        ID        EX        MEM       WB        notes
  12   00000048  00000044  00000040  0000003c  00000038  fwdA=EX/MEM
  13   0000004c  00000048  00000044  ...                 STALL (load-use)

Usage:
  pipeview.py build/waves/forwarding.fwd1.vcd [--start PC] [--cycles N]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CORE = "TOP.tb_top.u_core."
SIGS = {
    "clk": "TOP.tb_top.clk",
    "rst": "TOP.tb_top.rst",
    "if_pc": CORE + "dbg_if_pc",
    "id_pc": CORE + "dbg_id_pc", "id_v": CORE + "dbg_id_valid", "id_insn": CORE + "dbg_id_insn",
    "ex_pc": CORE + "dbg_ex_pc", "ex_v": CORE + "dbg_ex_valid", "ex_insn": CORE + "dbg_ex_insn",
    "mem_pc": CORE + "dbg_mem_pc", "mem_v": CORE + "dbg_mem_valid",
    "wb_pc": CORE + "dbg_wb_pc", "wb_v": CORE + "dbg_wb_valid",
    "stall": CORE + "stall", "lu": CORE + "stall_load_use", "flush": CORE + "flush",
    "fa": CORE + "fwd_a", "fb": CORE + "fwd_b", "halted": "TOP.tb_top.halted",
}
FWD = {0: None, 1: "EX/MEM", 2: "MEM/WB"}


def parse_vcd(path: Path) -> list[dict[str, int]]:
    """Return the value of every signal of interest at each rising clk edge."""
    want = set(SIGS.values())
    ids: dict[str, list[str]] = {}
    scope: list[str] = []
    text = path.read_text()
    head, body = text.split("$enddefinitions", 1)
    for m in re.finditer(r"\$scope \w+ (\S+) \$end|\$upscope \$end|\$var \S+ \d+ (\S+) (\S+)", head):
        if m.group(1):
            scope.append(m.group(1))
        elif m.group(0).startswith("$upscope"):
            scope.pop()
        else:
            name = ".".join(scope + [m.group(3)])
            if name in want:
                ids.setdefault(m.group(2), []).append(name)

    cur = {n: 0 for n in want}
    samples = []
    prev_clk = 0
    pending = []  # value changes in the current timestep

    def flush_step():
        nonlocal prev_clk
        # Signals are sampled *before* applying this timestep's changes when
        # the clock rises, i.e. the values that were present at the edge.
        clk_rises = any(n == SIGS["clk"] and v == 1 for n, v in pending) and prev_clk == 0
        if clk_rises:
            samples.append({k: cur[s] for k, s in SIGS.items()})
        for n, v in pending:
            cur[n] = v
            if n == SIGS["clk"]:
                prev_clk = v
        pending.clear()

    toks = iter(body.split())
    for tok in toks:
        if tok.startswith("#"):
            flush_step()
        elif tok[0] in "bB":                     # vector: b<bits> <id>
            ident = next(toks)
            if ident in ids:
                v = int(re.sub("[xXzZ]", "0", tok[1:]), 2)
                pending.extend((n, v) for n in ids[ident])
        elif tok[0] in "01xXzZ" and tok[1:] in ids:  # scalar: <bit><id>
            v = 1 if tok[0] == "1" else 0
            pending.extend((n, v) for n in ids[tok[1:]])
    flush_step()
    return samples


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vcd", type=Path)
    ap.add_argument("--start", type=lambda s: int(s, 0), help="start at the first cycle this PC is in IF")
    ap.add_argument("--skip", type=int, default=0, help="cycles to skip after reset")
    ap.add_argument("--cycles", type=int, default=30)
    args = ap.parse_args()

    s = [x for x in parse_vcd(args.vcd) if not x["rst"]]
    first = args.skip
    if args.start is not None:
        first = next((i for i, x in enumerate(s) if x["if_pc"] == args.start), 0)

    def stage(pc, valid=1):
        return f"{pc:08x}" if valid else "   --   "

    print(f"{'cyc':>5}  {'IF':8}  {'ID':8}  {'EX':8}  {'MEM':8}  {'WB':8}  notes")
    for i in range(first, min(first + args.cycles, len(s))):
        x = s[i]
        notes = []
        if x["stall"]:
            notes.append("STALL load-use" if x["lu"] else "STALL raw")
        if x["flush"]:
            notes.append("FLUSH (redirect)")
        if x["ex_v"]:
            for lab, k in (("rs1", "fa"), ("rs2", "fb")):
                if FWD[x[k]]:
                    notes.append(f"{lab}<-{FWD[x[k]]}")
        print(f"{i:5d}  {stage(x['if_pc'])}  {stage(x['id_pc'], x['id_v'])}  {stage(x['ex_pc'], x['ex_v'])}  "
              f"{stage(x['mem_pc'], x['mem_v'])}  {stage(x['wb_pc'], x['wb_v'])}  {', '.join(notes)}")
        if x["halted"]:
            break
    return 0


if __name__ == "__main__":
    sys.exit(main())
