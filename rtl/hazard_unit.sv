// hazard_unit.sv
//
// Data hazards (checked against the instruction in ID):
//   FORWARD_EN = 1 : only a load-use hazard stalls, for exactly one cycle.
//   FORWARD_EN = 0 : any RAW dependency on an instruction in EX or MEM
//                    stalls until the producer reaches WB (the register file
//                    write-through covers WB -> ID).
//
// Control hazards: branches and jumps resolve in EX. When one redirects the
// PC, the two younger instructions in IF/ID and ID/EX are flushed.
//
// A redirect always wins over a stall, because the stalled instruction in
// ID is on the wrong path and is about to be flushed anyway.

module hazard_unit #(
  parameter bit FORWARD_EN = 1'b1
) (
  // Instruction in ID
  input  logic       id_valid,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic       id_uses_rs1,
  input  logic       id_uses_rs2,

  // Instruction in EX
  input  logic       ex_reg_write,
  input  logic       ex_mem_read,
  input  logic [4:0] ex_rd,

  // Instruction in MEM
  input  logic       mem_reg_write,
  input  logic [4:0] mem_rd,

  // Redirect from EX (taken branch, JAL, JALR) or halt
  input  logic       ex_redirect,

  output logic       stall,          // hold PC and IF/ID, bubble into ID/EX
  output logic       flush,          // squash IF/ID and ID/EX
  output logic       stall_load_use, // perf: stall caused by a load
  output logic       stall_raw       // perf: stall caused by any RAW
);

  function automatic logic depends_on(input logic wr, input logic [4:0] rd);
    return wr && (rd != 5'd0) &&
           ((id_uses_rs1 && id_rs1 == rd) || (id_uses_rs2 && id_rs2 == rd));
  endfunction

  logic dep_ex, dep_mem, load_use, raw;

  assign dep_ex   = depends_on(ex_reg_write, ex_rd);
  assign dep_mem  = depends_on(mem_reg_write, mem_rd);
  assign load_use = id_valid && ex_mem_read && dep_ex;
  assign raw      = id_valid && (dep_ex || dep_mem);

  assign flush          = ex_redirect;
  assign stall_load_use = !flush && load_use;
  assign stall_raw      = !flush && (FORWARD_EN ? load_use : raw);
  assign stall          = stall_raw;

endmodule
