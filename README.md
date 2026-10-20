# Pipelined RISC-V Processor

A 5-stage pipelined processor in SystemVerilog that runs the full **RV32I**
base instruction set. It has a forwarding unit, a one-cycle load-use stall,
and pipeline flushes on taken branches and jumps. It is verified in
simulation with **Verilator** against a golden instruction-set model, and
waveforms can be viewed in **GTKWave**.

```
        +------+    +------+    +------+    +------+    +------+
  PC -> |  IF  | -> |  ID  | -> |  EX  | -> | MEM  | -> |  WB  |
        +------+    +------+    +------+    +------+    +------+
            ^           |  ^        ^ ^         |           |
            |  stall    |  | regfile| |  EX/MEM |   MEM/WB  |
            |  (hold)   |  | write- | +---------+           |
            |           |  | through|   forward             |
            |           |  +--------+-----------------------+
            |           |           ^      forward
            +-----------+-----------+
               flush / redirect on taken branch, JAL, JALR (resolved in EX)
```

## Features

| | |
|---|---|
| ISA | All 40 RV32I instructions: LUI, AUIPC, JAL, JALR, 6 branches, 5 loads, 3 stores, 9 immediate ALU ops, 10 register ALU ops, FENCE, ECALL, EBREAK |
| Pipeline | IF, ID, EX, MEM, WB with valid bits and bubbles |
| Forwarding | EX/MEM -> EX and MEM/WB -> EX on both operands; feeds the ALU, branch comparator, JALR target and store data. Newest producer wins; x0 is never forwarded |
| Register file | Write-through, so WB -> ID needs no forwarding or stall |
| Load-use | Exactly one stall cycle, then MEM/WB forwarding |
| Control hazards | Branches/jumps resolve in EX. A taken branch flushes IF/ID and ID/EX (2-cycle penalty, predict not-taken) |
| Halt | ECALL/EBREAK squashes younger instructions and stops fetch once it reaches EX |
| Build option | `FORWARD_EN=0` builds the same core with forwarding removed (stall until write-back) for comparison |

## Results

Data-hazard stall cycles with forwarding off vs on, from `make test`
(every program also passes its self-check and matches the golden model
commit-for-commit in both builds):

| program | instructions | stalls (no fwd) | stalls (fwd) | reduction | CPI (no fwd) | CPI (fwd) |
|---|---:|---:|---:|---:|---:|---:|
| bubble_sort | 4,273 | 1,782 | 559 | 68.6% | 1.80 | 1.51 |
| crc32 | 461 | 269 | 9 | 96.7% | 2.07 | 1.50 |
| fib | 22,897 | 12,949 | 0 | 100% | 2.00 | 1.43 |
| matmul | 62,137 | 45,562 | 0 | 100% | 2.07 | 1.33 |
| strings | 395 | 268 | 56 | 79.1% | 2.00 | 1.47 |
| all directed tests + benchmarks | 90,854 | 61,347 | 638 | **99.0%** | 2.04 | 1.37 |
| 500 random programs, seeds 1000-1499 (load-heavy by design) | 235,016 | 166,943 | 17,120 | **89.7%** | 1.93 | 1.29 |

With forwarding on, **every remaining data stall is a single load-use
cycle**. The reduction depends on how often a load is immediately consumed:
load-heavy code such as bubble sort keeps more stalls, ALU-heavy code such
as matmul keeps none.

## Verification

This is the part of the project that does the most work.

1. **Golden model diff.** `tools/rviss.py` is a plain one-instruction-at-a-time
   RV32I simulator. Both it and the RTL write a commit log, one line per
   retired instruction:
   ```
   <pc> <insn> [x<rd>=<value>] [st<size> <addr>=<value>]
   ```
   The logs must match line for line. Any missing forward, wrong stall or
   bad flush shows up as the first differing commit.
2. **Self-checking directed tests** (`tests/directed/`). Each sub-test sets
   `gp` to its number and branches to `fail` on a mismatch, so a failure
   names the exact case. `forwarding.S` covers 22 hazard cases (each forward
   path, priority, x0, store data/address, load-use on rs1/rs2, load into
   branch/JALR/store/load address, ...). `flush.S` checks that wrong-path
   instructions never write registers or memory and that a wrong-path ECALL
   does not halt.
3. **Benchmarks** (`tests/bench/`): bubble sort, 8x8 matrix multiply with
   software multiply, iterative + recursive Fibonacci, CRC-32 (checked
   against the standard `0xCBF43926`), and strlen/memcpy/memcmp.
4. **Constrained-random programs** (`tools/rvgen.py`). Source registers are
   biased toward the most recently written ones, loads are often consumed
   right away, and branches/JAL/JALR jump over real instructions (including
   stores) that must be squashed. The default run is 200 programs (~90k
   instructions) in both builds.
5. **Mutation testing** (`tools/mutation_test.py`). Twelve realistic hazard
   bugs are injected one at a time: no EX/MEM forward, wrong forward
   priority, x0 forwarded, no load-use stall, unforwarded store data,
   missing flush, and others. The suite must fail on every one. Current
   result: **12/12 caught**.
6. **Assembler cross-check** (`tools/check_asm_llvm.py`). The project's
   assembler output is compared to clang/lld. It is bit-identical except
   where LLVM picks a different but equally valid `li` expansion.
7. **Lint**: `verilator --lint-only -Wall` reports no warnings.

## Running it

Requirements: Verilator 5.x, a C++ compiler, Python 3.8+. GTKWave is
optional. No RISC-V toolchain is needed; `tools/rvasm.py` assembles the
tests.

```bash
make test                  # build both simulators, run everything
make test RANDOM=1000      # more random programs
make stats                 # forwarding on/off stall table only
make wave TEST=forwarding  # dump VCDs + print a pipeline diagram
make mutate                # mutation testing (~5 min)
make lint
```

Running a single program by hand:

```bash
python3 tools/rvasm.py tests/bench/crc32.S -o crc32.hex
build/fwd1/Vtb_top +hex=crc32.hex +trace=rtl.log +vcd=crc32.vcd
python3 tools/rviss.py crc32.hex --trace golden.log
diff rtl.log golden.log
```

### Waveforms

```bash
make wave TEST=forwarding
gtkwave build/waves/forwarding.fwd1.vcd sim/pipeline.gtkw
```

`sim/pipeline.gtkw` sets up the PC and instruction in every stage, stall,
flush, the forwarding selects (`0` = register file, `1` = EX/MEM, `2` =
MEM/WB) and the forwarded operand values. `tools/pipeview.py` prints the same
information as text. Here is a load-use stall (`lw` at `0x118`, `bne` at
`0x11c`):

```
  cyc  IF        ID        EX        MEM       WB        notes
   74  00000120  0000011c  00000118  00000114  00000110  STALL load-use
   75  00000120  0000011c     --     00000118  00000114
   76  00000124  00000120  0000011c     --     00000118  rs1<-MEM/WB
```

and a taken branch at `0x10` flushing the two instructions behind it:

```
    6  00000018  00000014  00000010  0000000c  00000008  FLUSH (redirect)
    7  00000020     --        --     00000010  0000000c
```

## Repository layout

```
rtl/
  rv32i_pkg.sv        opcodes, ALU ops, control bundle type
  core.sv             the 5-stage pipeline
  forwarding_unit.sv  EX/MEM and MEM/WB forwarding selects
  hazard_unit.sv      load-use / RAW stall and flush control
  control.sv          instruction decoder
  alu.sv  branch_unit.sv  imm_gen.sv  regfile.sv
  imem.sv  dmem.sv    simulation memories (64 KiB each)
tb/
  tb_top.sv           memories, commit log, perf counters, pass/fail
  sim_main.cpp        Verilator harness (+vcd= for waveforms)
tests/
  directed/*.S        self-checking ISA and hazard tests
  bench/*.S           benchmark programs
tools/
  rvasm.py            RV32I assembler -> $readmemh image
  rviss.py            golden instruction-set simulator
  rvgen.py            constrained-random program generator
  run_tests.py        regression runner + stall statistics
  mutation_test.py    bug-injection check of the test suite
  pipeview.py         text pipeline diagram from a VCD
  check_asm_llvm.py   assembler cross-check against LLVM
sim/pipeline.gtkw     GTKWave signal layout
```

## Limitations

- No exceptions, interrupts, CSRs or privilege modes. ECALL/EBREAK simply end
  the simulation.
- Memory accesses are assumed to be naturally aligned.
- Memories are simulation models with combinational reads, not synthesizable
  block RAM.
- No branch prediction: every taken branch costs two cycles.
