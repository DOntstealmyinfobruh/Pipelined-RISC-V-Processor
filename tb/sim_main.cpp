// sim_main.cpp - Verilator C++ harness for tb_top.
//
//   ./Vtb_top +hex=prog.hex [+trace=commit.log] [+perf=perf.txt] [+vcd=wave.vcd]
//
// +vcd=<file> dumps every signal for viewing in GTKWave.

#include <memory>
#include <string>

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char** argv) {
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);

    std::string vcd_arg = ctx->commandArgsPlusMatch("vcd=");
    std::string vcd_path;
    if (!vcd_arg.empty()) vcd_path = vcd_arg.substr(vcd_arg.find('=') + 1);

    ctx->traceEverOn(!vcd_path.empty());
    auto top = std::make_unique<Vtb_top>(ctx.get(), "TOP");

    std::unique_ptr<VerilatedVcdC> tfp;
    if (!vcd_path.empty()) {
        tfp = std::make_unique<VerilatedVcdC>();
        top->trace(tfp.get(), 99);
        tfp->open(vcd_path.c_str());
    }

    top->clk = 0;
    top->rst = 1;

    const int reset_cycles = 4;
    int half_cycles = 0;

    while (!ctx->gotFinish()) {
        if (half_cycles == reset_cycles * 2) top->rst = 0;
        top->clk = !top->clk;
        top->eval();
        if (tfp) tfp->dump(ctx->time());
        ctx->timeInc(5);  // 10-unit clock period
        ++half_cycles;
    }

    top->final();
    if (tfp) tfp->close();
    return 0;
}
