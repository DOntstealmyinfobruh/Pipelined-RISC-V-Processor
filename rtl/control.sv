// control.sv - main decoder. Turns an instruction word into the control
// bundle that travels down the pipeline. Unknown encodings decode as NOPs.

module control
  import rv32i_pkg::*;
(
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] insn,  // only opcode/funct3/funct7[5] matter here
  /* verilator lint_on UNUSEDSIGNAL */
  output ctrl_t       ctrl
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic       funct7_5;

  assign opcode   = insn[6:0];
  assign funct3   = insn[14:12];
  assign funct7_5 = insn[30];

  // ALU op for register-register and register-immediate arithmetic
  function automatic alu_op_e arith_op(input logic [2:0] f3, input logic sub_sra, input logic is_reg);
    unique case (f3)
      3'b000:  return (is_reg && sub_sra) ? ALU_SUB : ALU_ADD;
      3'b001:  return ALU_SLL;
      3'b010:  return ALU_SLT;
      3'b011:  return ALU_SLTU;
      3'b100:  return ALU_XOR;
      3'b101:  return sub_sra ? ALU_SRA : ALU_SRL;
      3'b110:  return ALU_OR;
      default: return ALU_AND;
    endcase
  endfunction

  always_comb begin
    ctrl = CTRL_NOP;
    ctrl.alu_src_a = SRC_A_RS1;
    ctrl.alu_op    = ALU_ADD;
    ctrl.wb_sel    = WB_ALU;

    unique case (opcode)
      OP_LUI: begin
        ctrl.reg_write = 1'b1;
        ctrl.alu_src_a = SRC_A_ZERO;
        ctrl.alu_src_b = 1'b1;
      end
      OP_AUIPC: begin
        ctrl.reg_write = 1'b1;
        ctrl.alu_src_a = SRC_A_PC;
        ctrl.alu_src_b = 1'b1;
      end
      OP_JAL: begin
        ctrl.reg_write = 1'b1;
        ctrl.jal       = 1'b1;
        ctrl.wb_sel    = WB_PC4;
      end
      OP_JALR: begin
        ctrl.reg_write = 1'b1;
        ctrl.jalr      = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.alu_src_b = 1'b1;
        ctrl.wb_sel    = WB_PC4;
      end
      OP_BRANCH: begin
        ctrl.branch    = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.uses_rs2  = 1'b1;
      end
      OP_LOAD: begin
        ctrl.reg_write = 1'b1;
        ctrl.mem_read  = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.alu_src_b = 1'b1;
        ctrl.wb_sel    = WB_MEM;
      end
      OP_STORE: begin
        ctrl.mem_write = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.uses_rs2  = 1'b1;
        ctrl.alu_src_b = 1'b1;
      end
      OP_IMM: begin
        ctrl.reg_write = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.alu_src_b = 1'b1;
        // funct7[5] only distinguishes SRAI from SRLI for immediates
        ctrl.alu_op    = arith_op(funct3, funct7_5 && (funct3 == 3'b101), 1'b0);
      end
      OP_REG: begin
        ctrl.reg_write = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.uses_rs2  = 1'b1;
        ctrl.alu_op    = arith_op(funct3, funct7_5, 1'b1);
      end
      OP_SYSTEM: begin
        // ECALL / EBREAK: stop the simulation when it retires
        if (funct3 == 3'b000) ctrl.halt = 1'b1;
      end
      OP_FENCE: ; // memory is in-order and coherent: FENCE is a NOP
      default: ; // unrecognised encodings behave as NOP
    endcase
  end

endmodule
