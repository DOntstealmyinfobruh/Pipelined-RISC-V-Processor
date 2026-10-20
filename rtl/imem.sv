// imem.sv - instruction memory for simulation (combinational read).
// Preloaded from the program hex image; unused words read as NOPs.

module imem #(
  parameter int WORDS = 16384  // 64 KiB
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] addr,   // only the word-index bits are used
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] rdata
);
  logic [31:0] mem [WORDS];

  assign rdata = mem[addr[$clog2(WORDS)+1:2]];

  task automatic load(input string path);
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;
    $readmemh(path, mem);
  endtask
endmodule
