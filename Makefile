# Pipelined RV32I processor - build and test
#
#   make            build the simulator (forwarding on) and run every test
#   make sim        build both simulators (forwarding on and off)
#   make test       directed + random tests, forwarding on and off
#   make stats      stall comparison, forwarding on vs off
#   make wave TEST=forwarding   dump build/waves/<test>.fwd{0,1}.vcd and print
#                               a cycle-by-cycle pipeline diagram
#   make mutate     inject hazard bugs and check the tests catch every one
#   make lint       Verilator lint with -Wall
#   make clean

VERILATOR ?= verilator
PYTHON    ?= python3

RTL := rtl/rv32i_pkg.sv rtl/alu.sv rtl/regfile.sv rtl/imm_gen.sv rtl/control.sv \
       rtl/branch_unit.sv rtl/forwarding_unit.sv rtl/hazard_unit.sv rtl/core.sv \
       rtl/imem.sv rtl/dmem.sv
TB  := tb/tb_top.sv
CPP := $(abspath tb/sim_main.cpp)

VFLAGS := --cc --exe --build -j 0 --trace -Wall -Wno-fatal \
          --top-module tb_top -O2 --x-assign fast --x-initial fast

SIM_FWD   := build/fwd1/Vtb_top
SIM_NOFWD := build/fwd0/Vtb_top
RANDOM    ?= 200
SEED      ?= 1

.PHONY: all sim test stats wave mutate lint clean

all: test

$(SIM_FWD): $(RTL) $(TB) $(CPP)
	@mkdir -p build/fwd1
	$(VERILATOR) $(VFLAGS) -GFORWARD_EN=1 --Mdir build/fwd1 $(RTL) $(TB) $(CPP)

$(SIM_NOFWD): $(RTL) $(TB) $(CPP)
	@mkdir -p build/fwd0
	$(VERILATOR) $(VFLAGS) -GFORWARD_EN=0 --Mdir build/fwd0 $(RTL) $(TB) $(CPP)

sim: $(SIM_FWD) $(SIM_NOFWD)

test: sim
	$(PYTHON) tools/run_tests.py --random $(RANDOM) --seed $(SEED)

stats: sim
	$(PYTHON) tools/run_tests.py --stats-only

TEST   ?= forwarding
CYCLES ?= 40
wave: sim
	$(PYTHON) tools/run_tests.py --only $(TEST) --vcd
	$(PYTHON) tools/pipeview.py build/waves/$(TEST).fwd1.vcd --cycles $(CYCLES)

mutate:
	$(PYTHON) tools/mutation_test.py --random 30

lint:
	$(VERILATOR) --lint-only -Wall --top-module tb_top $(RTL) $(TB)

clean:
	rm -rf build
