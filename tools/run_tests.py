#!/usr/bin/env python3
"""run_tests.py - regression runner.

For every program (directed tests, benchmarks, random programs) and for
both pipeline builds (forwarding on / off):
  1. assemble it (tools/rvasm.py)
  2. run it on the golden ISA model (tools/rviss.py) -> expected commit log
  3. run it on the Verilated RTL                     -> actual commit log
  4. require: the RTL halted, a0 == 0 (self-check), and the two commit logs
     are identical line for line (same PCs, same register writes, same
     stores, same order)

It then compares data-hazard stall cycles between the two builds.

Usage:
  run_tests.py                     directed + bench + 200 random programs
  run_tests.py --random 1000 --seed 5
  run_tests.py --only forwarding --vcd     dump build/waves/forwarding.vcd
  run_tests.py --stats-only        just the forwarding on/off comparison
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import rvasm  # noqa: E402
import rvgen  # noqa: E402
import rviss  # noqa: E402

BUILD = ROOT / "build"
SIMS = {1: BUILD / "fwd1" / "Vtb_top", 0: BUILD / "fwd0" / "Vtb_top"}


@dataclass
class Result:
    name: str
    forward: int
    ok: bool
    msg: str = ""
    perf: dict = field(default_factory=dict)


def assemble(src: Path, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    hex_path = out_dir / (src.stem + ".hex")
    words, _ = rvasm.assemble_file(str(src))
    rvasm.write_hex(words, str(hex_path))
    return hex_path


def golden(hex_path: Path) -> list[str]:
    iss = rviss.ISS(rviss.read_hex(str(hex_path)))
    if not iss.run():
        raise RuntimeError("golden model did not halt")
    return iss.log


def run_rtl(hex_path: Path, forward: int, work: Path, vcd: Path | None = None) -> tuple[list[str], dict, str]:
    work.mkdir(parents=True, exist_ok=True)
    trace = work / f"{hex_path.stem}.fwd{forward}.log"
    perf = work / f"{hex_path.stem}.fwd{forward}.perf"
    cmd = [str(SIMS[forward]), f"+hex={hex_path}", f"+trace={trace}", f"+perf={perf}"]
    if vcd:
        cmd.append(f"+vcd={vcd}")
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    stats = {}
    if perf.exists():
        for line in perf.read_text().split():
            k, v = line.split("=")
            stats[k] = int(v)
    log = trace.read_text().splitlines() if trace.exists() else []
    return log, stats, proc.stdout + proc.stderr


def check(name: str, hex_path: Path, forward: int, expect: list[str],
          self_checking: bool, work: Path, vcd: Path | None = None) -> Result:
    log, perf, out = run_rtl(hex_path, forward, work, vcd)
    if not perf.get("halted"):
        return Result(name, forward, False, "did not halt: " + out.strip().splitlines()[0] if out else "no output", perf)
    if self_checking and perf.get("a0", 1) != 0:
        return Result(name, forward, False, f"self-check failed at sub-test {perf['a0']}", perf)
    for i, (got, want) in enumerate(zip(log, expect)):
        if got != want:
            return Result(name, forward, False,
                          f"commit #{i} differs\n      rtl:    {got}\n      golden: {want}", perf)
    if len(log) != len(expect):
        return Result(name, forward, False, f"retired {len(log)} instructions, golden model {len(expect)}", perf)
    return Result(name, forward, True, "", perf)


def pct(a: int, b: int) -> str:
    return f"{100.0 * (1 - a / b):.1f}%" if b else "n/a"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--random", type=int, default=200, help="number of random programs")
    ap.add_argument("--seed", type=int, default=1, help="first random seed")
    ap.add_argument("--length", type=int, default=300, help="random program length")
    ap.add_argument("--only", help="run only the named directed/bench test")
    ap.add_argument("--vcd", action="store_true", help="dump a VCD for GTKWave (with --only)")
    ap.add_argument("--stats-only", action="store_true")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 2)
    args = ap.parse_args()

    for f, sim in SIMS.items():
        if not sim.exists():
            print(f"missing {sim} - run 'make sim' first", file=sys.stderr)
            return 2

    work = BUILD / "run"
    sources = sorted((ROOT / "tests" / "directed").glob("*.S")) + sorted((ROOT / "tests" / "bench").glob("*.S"))
    if args.only:
        sources = [s for s in sources if s.stem == args.only]
        if not sources:
            print(f"no test named '{args.only}'", file=sys.stderr)
            return 2

    # ---------------------------------------------------------------- jobs
    jobs = []  # (name, kind, hex, golden_log, self_checking)
    for src in sources:
        hx = assemble(src, BUILD / "hex")
        jobs.append((src.stem, src.parent.name, hx, golden(hx), True))

    if not args.only and not args.stats_only and args.random > 0:
        rdir = BUILD / "random"
        rdir.mkdir(parents=True, exist_ok=True)
        for s in range(args.seed, args.seed + args.random):
            src = rdir / f"rand_{s}.S"
            src.write_text(rvgen.Gen(s).program(args.length))
            hx = assemble(src, BUILD / "hex")
            jobs.append((src.stem, "random", hx, golden(hx), False))

    vcd_dir = BUILD / "waves"
    vcd_dir.mkdir(parents=True, exist_ok=True)
    tasks = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for name, kind, hx, gold, sc in jobs:
            for fwd in (1, 0):
                vcd = vcd_dir / f"{name}.fwd{fwd}.vcd" if args.vcd else None
                tasks.append((kind, pool.submit(check, name, hx, fwd, gold, sc, work, vcd)))
    results = [(k, t.result()) for k, t in tasks]

    # ------------------------------------------------------------- report
    failed = [r for _, r in results if not r.ok]
    if not args.stats_only:
        by_kind: dict[str, list[Result]] = {}
        for k, r in results:
            by_kind.setdefault(k, []).append(r)
        print("\n== Verification ==")
        for k in ("directed", "bench", "random"):
            rs = by_kind.get(k, [])
            if not rs:
                continue
            n_ok = sum(r.ok for r in rs)
            instr = sum(r.perf.get("instret", 0) for r in rs if r.forward == 1)
            print(f"  {k:9s} {n_ok:4d}/{len(rs):<4d} runs passed   "
                  f"({len(rs) // 2} programs x 2 builds, {instr:,} instructions compared per build)")
        for r in failed:
            print(f"  FAIL {r.name} (forward={r.forward}): {r.msg}")

    # Stall comparison on the directed tests and benchmarks
    rows = []
    for k, r in results:
        if k == "random" or r.forward != 1:
            continue
        r0 = next(x for kk, x in results if x.name == r.name and x.forward == 0)
        rows.append((r.name, r, r0))

    if rows:
        print("\n== Data-hazard stalls: forwarding OFF vs ON ==")
        hdr = f"  {'program':14s} {'instret':>8s} {'stalls off':>11s} {'stalls on':>10s} {'reduction':>10s} {'CPI off':>8s} {'CPI on':>7s}"
        print(hdr)
        print("  " + "-" * (len(hdr) - 2))
        tot = {"i": 0, "s0": 0, "s1": 0, "c0": 0, "c1": 0}
        for name, r1, r0 in rows:
            i = r1.perf.get("instret", 0)
            s1, s0 = r1.perf.get("data_stalls", 0), r0.perf.get("data_stalls", 0)
            c1, c0 = r1.perf.get("cycles", 0), r0.perf.get("cycles", 0)
            tot["i"] += i; tot["s0"] += s0; tot["s1"] += s1; tot["c0"] += c0; tot["c1"] += c1
            print(f"  {name:14s} {i:8d} {s0:11d} {s1:10d} {pct(s1, s0):>10s} {c0 / i:8.2f} {c1 / i:7.2f}")
        print("  " + "-" * (len(hdr) - 2))
        print(f"  {'TOTAL':14s} {tot['i']:8d} {tot['s0']:11d} {tot['s1']:10d} {pct(tot['s1'], tot['s0']):>10s} "
              f"{tot['c0'] / tot['i']:8.2f} {tot['c1'] / tot['i']:7.2f}")
        lu = sum(r1.perf.get("load_use_stalls", 0) for _, r1, _ in rows)
        print(f"\n  With forwarding on, {lu} of {tot['s1']} remaining stall cycles are load-use (1 cycle each).")

    if args.vcd:
        print(f"\nVCD written to build/waves/ - view with:  gtkwave build/waves/{args.only}.fwd1.vcd sim/pipeline.gtkw")

    print(f"\n{'ALL PASSED' if not failed else f'{len(failed)} FAILED'}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
