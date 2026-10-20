// dmem.sv - data memory for simulation.
// Combinational read, byte-masked synchronous write. Preloaded from the
// same hex image as imem so programs can keep initialised data next to code.

module dmem #(
  parameter int WORDS = 16384  // 64 KiB
) (
  input  logic        clk,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] addr,   // only the word-index bits are used
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] rdata,
  input  logic        we,
  input  logic [3:0]  wstrb,
  input  logic [31:0] wdata
);
  logic [31:0] mem [WORDS];
  localparam int AW = $clog2(WORDS);

  assign rdata = mem[addr[AW+1:2]];

  always_ff @(posedge clk) begin
    if (we) begin
      for (int b = 0; b < 4; b++)
        if (wstrb[b]) mem[addr[AW+1:2]][b*8 +: 8] <= wdata[b*8 +: 8];
    end
  end

  task automatic load(input string path);
    for (int i = 0; i < WORDS; i++) mem[i] = '0;
    $readmemh(path, mem);
  endtask
endmodule
