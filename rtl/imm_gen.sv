// imm_gen.sv - immediate extraction for all RV32I formats

module imm_gen
  import rv32i_pkg::*;
(
  input  logic [31:0] insn,
  output logic [31:0] imm
);

  logic [6:0] opcode;
  assign opcode = insn[6:0];

  always_comb begin
    unique case (opcode)
      // I-type
      OP_IMM, OP_LOAD, OP_JALR:
        imm = {{20{insn[31]}}, insn[31:20]};
      // S-type
      OP_STORE:
        imm = {{20{insn[31]}}, insn[31:25], insn[11:7]};
      // B-type
      OP_BRANCH:
        imm = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
      // U-type
      OP_LUI, OP_AUIPC:
        imm = {insn[31:12], 12'b0};
      // J-type
      OP_JAL:
        imm = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};
      default:
        imm = '0;
    endcase
  end

endmodule
