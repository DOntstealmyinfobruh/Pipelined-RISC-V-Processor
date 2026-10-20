// branch_unit.sv - evaluates the six RV32I branch conditions in EX.
// Operands arrive after the forwarding muxes, so branches that depend on
// the previous instruction resolve without stalling.

module branch_unit (
  input  logic [2:0]  funct3,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        taken
);

  always_comb begin
    unique case (funct3)
      3'b000:  taken = (a == b);                    // BEQ
      3'b001:  taken = (a != b);                    // BNE
      3'b100:  taken = ($signed(a) <  $signed(b));  // BLT
      3'b101:  taken = ($signed(a) >= $signed(b));  // BGE
      3'b110:  taken = (a <  b);                    // BLTU
      3'b111:  taken = (a >= b);                    // BGEU
      default: taken = 1'b0;
    endcase
  end

endmodule
