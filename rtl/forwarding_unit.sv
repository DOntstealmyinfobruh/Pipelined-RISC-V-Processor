// forwarding_unit.sv
//
// Picks where each EX-stage source operand comes from. The newest producer
// wins: a match in EX/MEM (one instruction ahead) has priority over a match
// in MEM/WB (two ahead). Writes to x0 are never forwarded.
//
// A load sitting in EX/MEM is never forwarded from here: its data does not
// exist until the end of MEM. The hazard unit inserts one bubble for that
// case, after which the load is in MEM/WB and the normal path applies.
//
// With FORWARD_EN = 0 every operand comes from the register file and the
// hazard unit is responsible for stalling until results are written back.

module forwarding_unit
  import rv32i_pkg::*;
#(
  parameter bit FORWARD_EN = 1'b1
) (
  input  logic [4:0] ex_rs1,
  input  logic [4:0] ex_rs2,

  input  logic       exmem_reg_write,
  input  logic [4:0] exmem_rd,

  input  logic       memwb_reg_write,
  input  logic [4:0] memwb_rd,

  output fwd_sel_e   fwd_a,
  output fwd_sel_e   fwd_b
);

  function automatic fwd_sel_e pick(input logic [4:0] rs);
    if (!FORWARD_EN || rs == 5'd0)
      return FWD_REG;
    else if (exmem_reg_write && exmem_rd == rs)
      return FWD_EXMEM;
    else if (memwb_reg_write && memwb_rd == rs)
      return FWD_MEMWB;
    else
      return FWD_REG;
  endfunction

  assign fwd_a = pick(ex_rs1);
  assign fwd_b = pick(ex_rs2);

endmodule
