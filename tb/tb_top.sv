// tb_top.sv - simulation top for Verilator.
//
// Plusargs:
//   +hex=<file>        program image ($readmemh, one 32-bit word per line)
//   +trace=<file>      write a commit log (one line per retired instruction)
//   +perf=<file>       write performance counters as key=value pairs
//   +max_cycles=<n>    timeout (default 2,000,000)
//
// The C++ harness (sim_main.cpp) drives clk/rst and optional VCD dumping.
// On ECALL/EBREAK the testbench prints a0 (x10): 0 means PASS, anything else
// is the number of the sub-test that failed.

module tb_top
  import rv32i_pkg::*;
#(
  parameter int FORWARD_EN = 1  // set with -GFORWARD_EN=0/1
) (
  input logic clk,
  input logic rst
);

  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic        dmem_we;
  logic [3:0]  dmem_wstrb;
  logic        halted;

  logic        retire_valid, retire_rd_we, retire_store;
  logic [31:0] retire_pc, retire_insn, retire_rd_data;
  logic [31:0] retire_store_addr, retire_store_data;
  logic [4:0]  retire_rd;
  logic [2:0]  retire_store_size;
  logic        perf_stall_data, perf_stall_load_use, perf_flush;

  core #(.FORWARD_EN(FORWARD_EN != 0)) u_core (
    .clk, .rst,
    .imem_addr, .imem_rdata,
    .dmem_addr, .dmem_we, .dmem_wstrb, .dmem_wdata, .dmem_rdata,
    .halted,
    .retire_valid, .retire_pc, .retire_insn,
    .retire_rd_we, .retire_rd, .retire_rd_data,
    .retire_store, .retire_store_addr, .retire_store_data, .retire_store_size,
    .perf_stall_data, .perf_stall_load_use, .perf_flush
  );

  imem u_imem (.addr(imem_addr), .rdata(imem_rdata));

  dmem u_dmem (
    .clk, .addr(dmem_addr), .rdata(dmem_rdata),
    .we(dmem_we), .wstrb(dmem_wstrb), .wdata(dmem_wdata)
  );

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------
  string  hex_path, trace_path, perf_path;
  int     trace_fd;
  longint max_cycles;

  initial begin
    if (!$value$plusargs("hex=%s", hex_path)) begin
      $display("ERROR: no +hex=<file> given");
      $finish;
    end
    u_imem.load(hex_path);
    u_dmem.load(hex_path);

    trace_fd = 0;
    if ($value$plusargs("trace=%s", trace_path)) trace_fd = $fopen(trace_path, "w");
    if (!$value$plusargs("perf=%s", perf_path)) perf_path = "";
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 2_000_000;
  end

  // ---------------------------------------------------------------------------
  // Commit log - same format the golden model (tools/rviss.py) produces
  //   <pc> <insn> [x<rd>=<value>] [st<size> <addr>=<value>]
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst && retire_valid && trace_fd != 0) begin
      $fwrite(trace_fd, "%08h %08h", retire_pc, retire_insn);
      if (retire_rd_we)
        $fwrite(trace_fd, " x%0d=%08h", retire_rd, retire_rd_data);
      if (retire_store)
        $fwrite(trace_fd, " st%0d %08h=%08h", retire_store_size, retire_store_addr, retire_store_data);
      $fwrite(trace_fd, "\n");
    end
  end

  // ---------------------------------------------------------------------------
  // Performance counters
  // ---------------------------------------------------------------------------
  longint cycles, instret, stalls_data, stalls_load_use, flushes;

  always_ff @(posedge clk) begin
    if (rst) begin
      cycles <= 0; instret <= 0; stalls_data <= 0; stalls_load_use <= 0; flushes <= 0;
    end else begin
      cycles          <= cycles + 1;
      instret         <= instret + longint'(retire_valid);
      stalls_data     <= stalls_data + longint'(perf_stall_data);
      stalls_load_use <= stalls_load_use + longint'(perf_stall_load_use);
      flushes         <= flushes + longint'(perf_flush);
    end
  end

  // ---------------------------------------------------------------------------
  // End of simulation
  // ---------------------------------------------------------------------------
  // Testbench-only end-of-test block: blocking assignments are intentional.
  /* verilator lint_off BLKSEQ */
  int perf_fd;
  logic [31:0] a0;

  always @(posedge clk) begin
    if (!rst && (halted || cycles >= max_cycles)) begin
      a0 = u_core.u_regfile.regs[10];
      if (!halted)
        $display("TIMEOUT after %0d cycles (pc=%08h)", cycles, u_core.pc);
      else if (a0 == 0)
        $display("PASS");
      else
        $display("FAIL (a0=%0d)", a0);

      $display("cycles=%0d instret=%0d data_stalls=%0d load_use_stalls=%0d flushes=%0d forward=%0d",
               cycles, instret, stalls_data, stalls_load_use, flushes, FORWARD_EN);

      if (perf_path != "") begin
        perf_fd = $fopen(perf_path, "w");
        $fwrite(perf_fd, "halted=%0d\na0=%0d\ncycles=%0d\ninstret=%0d\ndata_stalls=%0d\nload_use_stalls=%0d\nflushes=%0d\nforward=%0d\n",
                halted, a0, cycles, instret, stalls_data, stalls_load_use, flushes, FORWARD_EN);
        $fclose(perf_fd);
      end
      if (trace_fd != 0) $fclose(trace_fd);
      $finish;
    end
  end
  /* verilator lint_on BLKSEQ */

endmodule
