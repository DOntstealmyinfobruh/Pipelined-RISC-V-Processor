// rv32i_pkg.sv
// Shared constants and types for the 5-stage RV32I pipeline.

package rv32i_pkg;

  // ---------------------------------------------------------------------------
  // Opcodes (inst[6:0])
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;
  localparam logic [6:0] OP_REG    = 7'b0110011;
  localparam logic [6:0] OP_FENCE  = 7'b0001111;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;

  // Canonical NOP (addi x0, x0, 0)
  localparam logic [31:0] NOP_INSN = 32'h0000_0013;

  // ---------------------------------------------------------------------------
  // ALU operations
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_SLL,
    ALU_SLT,
    ALU_SLTU,
    ALU_XOR,
    ALU_SRL,
    ALU_SRA,
    ALU_OR,
    ALU_AND
  } alu_op_e;

  // ALU operand A source
  typedef enum logic [1:0] {
    SRC_A_RS1,
    SRC_A_PC,
    SRC_A_ZERO
  } src_a_e;

  // Writeback source
  typedef enum logic [1:0] {
    WB_ALU,
    WB_MEM,
    WB_PC4
  } wb_sel_e;

  // Forwarding mux select (one per EX operand)
  typedef enum logic [1:0] {
    FWD_REG,    // value read from the register file in ID
    FWD_EXMEM,  // result of the instruction one ahead (in MEM)
    FWD_MEMWB   // result of the instruction two ahead (in WB)
  } fwd_sel_e;

  // ---------------------------------------------------------------------------
  // Decoded control bundle carried down the pipeline
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic    reg_write;
    logic    mem_read;
    logic    mem_write;
    logic    branch;
    logic    jal;
    logic    jalr;
    logic    halt;      // ECALL / EBREAK end the simulation
    logic    uses_rs1;
    logic    uses_rs2;
    logic    alu_src_b; // 0 = rs2, 1 = immediate
    src_a_e  alu_src_a;
    alu_op_e alu_op;
    wb_sel_e wb_sel;
  } ctrl_t;

  localparam ctrl_t CTRL_NOP = '0;

endpackage
