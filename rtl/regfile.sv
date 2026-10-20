// regfile.sv - 32 x 32-bit register file, 2 read / 1 write.
//
// x0 is hardwired to zero. Reads are combinational and include a
// write-through bypass: if WB writes a register in the same cycle ID reads
// it, ID sees the new value. This removes the WB->ID hazard so neither the
// forwarding unit nor the stall logic has to cover a three-instruction gap.

module regfile (
  input  logic        clk,
  input  logic        rst,

  input  logic [4:0]  raddr1,
  output logic [31:0] rdata1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata2,

  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata
);

  logic [31:0] regs [32];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 32; i++) regs[i] <= '0;
    end else if (we && waddr != 5'd0) begin
      regs[waddr] <= wdata;
    end
  end

  always_comb begin
    if (raddr1 == 5'd0)                  rdata1 = '0;
    else if (we && waddr == raddr1)      rdata1 = wdata;
    else                                 rdata1 = regs[raddr1];

    if (raddr2 == 5'd0)                  rdata2 = '0;
    else if (we && waddr == raddr2)      rdata2 = wdata;
    else                                 rdata2 = regs[raddr2];
  end

endmodule
