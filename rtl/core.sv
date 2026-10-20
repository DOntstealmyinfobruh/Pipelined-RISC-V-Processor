// core.sv - 5-stage pipelined RV32I core
//
//   IF  -> ID  -> EX  -> MEM -> WB
//
// * Branches, JAL and JALR resolve in EX. A redirect flushes IF/ID and ID/EX
//   (2-cycle penalty); there is no branch predictor (predict not-taken).
// * Forwarding paths EX/MEM -> EX and MEM/WB -> EX feed the ALU, the branch
//   comparator, the JALR target adder and the store-data path.
// * The register file writes through, covering WB -> ID.
// * A load followed by a dependent instruction costs one stall cycle.
// * ECALL/EBREAK halts: once it reaches EX, fetch stops and younger
//   instructions are squashed, so nothing after it touches memory.
//
// The retire_* outputs describe each instruction as it leaves WB. The
// testbench turns them into a commit log that is diffed against the
// Python golden model.

module core
  import rv32i_pkg::*;
#(
  parameter bit          FORWARD_EN = 1'b1,
  parameter logic [31:0] RESET_PC   = 32'h0000_0000
) (
  input  logic        clk,
  input  logic        rst,

  // Instruction memory (combinational read)
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,

  // Data memory (combinational read, synchronous byte-masked write)
  output logic [31:0] dmem_addr,
  output logic        dmem_we,
  output logic [3:0]  dmem_wstrb,
  output logic [31:0] dmem_wdata,
  input  logic [31:0] dmem_rdata,

  output logic        halted,

  // Retirement (WB) trace port
  output logic        retire_valid,
  output logic [31:0] retire_pc,
  output logic [31:0] retire_insn,
  output logic        retire_rd_we,
  output logic [4:0]  retire_rd,
  output logic [31:0] retire_rd_data,
  output logic        retire_store,
  output logic [31:0] retire_store_addr,
  output logic [31:0] retire_store_data,
  output logic [2:0]  retire_store_size,  // bytes: 1, 2 or 4

  // Performance events (one pulse per cycle)
  output logic        perf_stall_data,     // data-hazard stall cycle
  output logic        perf_stall_load_use, // ...of which caused by a load
  output logic        perf_flush           // taken branch / jump redirect
);

  // ===========================================================================
  // Pipeline registers
  // ===========================================================================
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] insn;
  } if_id_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] insn;
    ctrl_t       ctrl;
    logic [2:0]  funct3;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] imm;
  } id_ex_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] insn;
    logic        reg_write;
    logic        mem_read;
    logic        mem_write;
    logic        halt;
    logic [2:0]  funct3;
    logic [4:0]  rd;
    logic [31:0] result;     // ALU result, or PC+4 for JAL/JALR
    logic [31:0] store_val;  // forwarded rs2 for stores
  } ex_mem_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] insn;
    logic        reg_write;
    logic        halt;
    logic [4:0]  rd;
    logic [31:0] wb_data;
    logic        store;
    logic [31:0] store_addr;
    logic [31:0] store_data;
    logic [2:0]  store_size;
  } mem_wb_t;

  if_id_t  if_id;
  id_ex_t  id_ex;
  ex_mem_t ex_mem;
  mem_wb_t mem_wb;

  // Hazard / control signals
  logic        stall, flush;
  logic        ex_redirect;
  logic [31:0] ex_target;
  logic        halt_seen;   // sticky: a halt instruction has reached EX

  // ===========================================================================
  // IF
  // ===========================================================================
  logic [31:0] pc;

  assign imem_addr = pc;

  always_ff @(posedge clk) begin
    if (rst)               pc <= RESET_PC;
    else if (ex_redirect)  pc <= ex_target;
    else if (!stall && !halt_seen) pc <= pc + 32'd4;
  end

  always_ff @(posedge clk) begin
    if (rst || flush || halt_seen) begin
      if_id <= '{valid: 1'b0, pc: '0, insn: NOP_INSN};
    end else if (!stall) begin
      if_id <= '{valid: 1'b1, pc: pc, insn: imem_rdata};
    end
  end

  // ===========================================================================
  // ID
  // ===========================================================================
  ctrl_t       id_ctrl;
  logic [31:0] id_imm;
  logic [31:0] rf_rdata1, rf_rdata2;
  logic [4:0]  id_rs1, id_rs2, id_rd;

  assign id_rs1 = if_id.insn[19:15];
  assign id_rs2 = if_id.insn[24:20];
  assign id_rd  = if_id.insn[11:7];

  control u_control (.insn(if_id.insn), .ctrl(id_ctrl));
  imm_gen u_imm_gen (.insn(if_id.insn), .imm(id_imm));

  // WB-stage write port signals (driven in WB section)
  logic        wb_we;
  logic [4:0]  wb_rd;
  logic [31:0] wb_data;

  regfile u_regfile (
    .clk    (clk),
    .rst    (rst),
    .raddr1 (id_rs1),
    .rdata1 (rf_rdata1),
    .raddr2 (id_rs2),
    .rdata2 (rf_rdata2),
    .we     (wb_we),
    .waddr  (wb_rd),
    .wdata  (wb_data)
  );

  logic stall_load_use, stall_raw;

  hazard_unit #(.FORWARD_EN(FORWARD_EN)) u_hazard (
    .id_valid       (if_id.valid),
    .id_rs1         (id_rs1),
    .id_rs2         (id_rs2),
    .id_uses_rs1    (id_ctrl.uses_rs1),
    .id_uses_rs2    (id_ctrl.uses_rs2),
    .ex_reg_write   (id_ex.valid && id_ex.ctrl.reg_write),
    .ex_mem_read    (id_ex.valid && id_ex.ctrl.mem_read),
    .ex_rd          (id_ex.rd),
    .mem_reg_write  (ex_mem.valid && ex_mem.reg_write),
    .mem_rd         (ex_mem.rd),
    .ex_redirect    (ex_redirect),
    .stall          (stall),
    .flush          (flush),
    .stall_load_use (stall_load_use),
    .stall_raw      (stall_raw)
  );

  always_ff @(posedge clk) begin
    if (rst || flush || stall || !if_id.valid) begin
      id_ex <= '0;  // bubble
    end else begin
      id_ex <= '{
        valid:   1'b1,
        pc:      if_id.pc,
        insn:    if_id.insn,
        ctrl:    id_ctrl,
        funct3:  if_id.insn[14:12],
        rs1:     id_ctrl.uses_rs1 ? id_rs1 : 5'd0,
        rs2:     id_ctrl.uses_rs2 ? id_rs2 : 5'd0,
        rd:      id_ctrl.reg_write ? id_rd : 5'd0,
        rs1_val: rf_rdata1,
        rs2_val: rf_rdata2,
        imm:     id_imm
      };
    end
  end

  // ===========================================================================
  // EX
  // ===========================================================================
  fwd_sel_e    fwd_a, fwd_b;
  logic [31:0] ex_rs1_val, ex_rs2_val;
  logic [31:0] alu_a, alu_b, alu_y;
  logic        br_taken;

  forwarding_unit #(.FORWARD_EN(FORWARD_EN)) u_fwd (
    .ex_rs1          (id_ex.rs1),
    .ex_rs2          (id_ex.rs2),
    .exmem_reg_write (ex_mem.valid && ex_mem.reg_write && !ex_mem.mem_read),
    .exmem_rd        (ex_mem.rd),
    .memwb_reg_write (mem_wb.valid && mem_wb.reg_write),
    .memwb_rd        (mem_wb.rd),
    .fwd_a           (fwd_a),
    .fwd_b           (fwd_b)
  );

  always_comb begin
    unique case (fwd_a)
      FWD_EXMEM: ex_rs1_val = ex_mem.result;
      FWD_MEMWB: ex_rs1_val = mem_wb.wb_data;
      default:   ex_rs1_val = id_ex.rs1_val;
    endcase
    unique case (fwd_b)
      FWD_EXMEM: ex_rs2_val = ex_mem.result;
      FWD_MEMWB: ex_rs2_val = mem_wb.wb_data;
      default:   ex_rs2_val = id_ex.rs2_val;
    endcase
  end

  always_comb begin
    unique case (id_ex.ctrl.alu_src_a)
      SRC_A_PC:   alu_a = id_ex.pc;
      SRC_A_ZERO: alu_a = '0;
      default:    alu_a = ex_rs1_val;
    endcase
    alu_b = id_ex.ctrl.alu_src_b ? id_ex.imm : ex_rs2_val;
  end

  alu u_alu (.op(id_ex.ctrl.alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

  branch_unit u_branch (
    .funct3 (id_ex.funct3),
    .a      (ex_rs1_val),
    .b      (ex_rs2_val),
    .taken  (br_taken)
  );

  logic ex_take, ex_halt;

  assign ex_take = id_ex.valid &&
                   (id_ex.ctrl.jal || id_ex.ctrl.jalr || (id_ex.ctrl.branch && br_taken));
  assign ex_halt = id_ex.valid && id_ex.ctrl.halt;

  always_comb begin
    if (id_ex.ctrl.jalr) ex_target = (ex_rs1_val + id_ex.imm) & ~32'd1;
    else                 ex_target = id_ex.pc + id_ex.imm;
  end

  // A halt reaching EX is treated like a redirect to itself: it squashes the
  // younger instructions, and halt_seen keeps fetch frozen afterwards.
  assign ex_redirect = ex_take || ex_halt;

  always_ff @(posedge clk) begin
    if (rst)          halt_seen <= 1'b0;
    else if (ex_halt) halt_seen <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst || !id_ex.valid) begin
      ex_mem <= '0;
    end else begin
      ex_mem <= '{
        valid:     1'b1,
        pc:        id_ex.pc,
        insn:      id_ex.insn,
        reg_write: id_ex.ctrl.reg_write,
        mem_read:  id_ex.ctrl.mem_read,
        mem_write: id_ex.ctrl.mem_write,
        halt:      id_ex.ctrl.halt,
        funct3:    id_ex.funct3,
        rd:        id_ex.rd,
        result:    (id_ex.ctrl.wb_sel == WB_PC4) ? id_ex.pc + 32'd4 : alu_y,
        store_val: ex_rs2_val
      };
    end
  end

  // ===========================================================================
  // MEM
  // ===========================================================================
  logic [1:0]  byte_off;
  logic [31:0] load_val;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] shifted;  // upper half unused for byte/half loads
  /* verilator lint_on UNUSEDSIGNAL */
  logic [2:0]  store_size;
  logic [31:0] store_masked;

  assign byte_off  = ex_mem.result[1:0];
  assign dmem_addr = {ex_mem.result[31:2], 2'b00};
  assign dmem_we   = ex_mem.valid && ex_mem.mem_write;

  // Store: replicate the data across the word and enable the right bytes
  always_comb begin
    unique case (ex_mem.funct3[1:0])
      2'b00: begin
        dmem_wdata   = {4{ex_mem.store_val[7:0]}};
        dmem_wstrb   = 4'b0001 << byte_off;
        store_size   = 3'd1;
        store_masked = {24'b0, ex_mem.store_val[7:0]};
      end
      2'b01: begin
        dmem_wdata   = {2{ex_mem.store_val[15:0]}};
        dmem_wstrb   = byte_off[1] ? 4'b1100 : 4'b0011;
        store_size   = 3'd2;
        store_masked = {16'b0, ex_mem.store_val[15:0]};
      end
      default: begin
        dmem_wdata   = ex_mem.store_val;
        dmem_wstrb   = 4'b1111;
        store_size   = 3'd4;
        store_masked = ex_mem.store_val;
      end
    endcase
  end

  // Load: shift the addressed bytes down, then sign/zero extend
  always_comb begin
    shifted = dmem_rdata >> {byte_off, 3'b000};
    unique case (ex_mem.funct3)
      3'b000:  load_val = {{24{shifted[7]}},  shifted[7:0]};   // LB
      3'b001:  load_val = {{16{shifted[15]}}, shifted[15:0]};  // LH
      3'b100:  load_val = {24'b0, shifted[7:0]};               // LBU
      3'b101:  load_val = {16'b0, shifted[15:0]};              // LHU
      default: load_val = dmem_rdata;                          // LW
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst || !ex_mem.valid) begin
      mem_wb <= '0;
    end else begin
      mem_wb <= '{
        valid:      1'b1,
        pc:         ex_mem.pc,
        insn:       ex_mem.insn,
        reg_write:  ex_mem.reg_write,
        halt:       ex_mem.halt,
        rd:         ex_mem.rd,
        wb_data:    ex_mem.mem_read ? load_val : ex_mem.result,
        store:      ex_mem.mem_write,
        store_addr: ex_mem.result,
        store_data: store_masked,
        store_size: store_size
      };
    end
  end

  // ===========================================================================
  // WB
  // ===========================================================================
  assign wb_we   = mem_wb.valid && mem_wb.reg_write;
  assign wb_rd   = mem_wb.rd;
  assign wb_data = mem_wb.wb_data;

  always_ff @(posedge clk) begin
    if (rst)                                halted <= 1'b0;
    else if (mem_wb.valid && mem_wb.halt)   halted <= 1'b1;
  end

  // ===========================================================================
  // Trace / performance outputs
  // ===========================================================================
  assign retire_valid      = mem_wb.valid;
  assign retire_pc         = mem_wb.pc;
  assign retire_insn       = mem_wb.insn;
  assign retire_rd_we      = mem_wb.reg_write && mem_wb.rd != 5'd0;
  assign retire_rd         = mem_wb.rd;
  assign retire_rd_data    = mem_wb.wb_data;
  assign retire_store      = mem_wb.store;
  assign retire_store_addr = mem_wb.store_addr;
  assign retire_store_data = mem_wb.store_data;
  assign retire_store_size = mem_wb.store_size;

  assign perf_stall_data     = stall_raw;
  assign perf_stall_load_use = stall_load_use;
  assign perf_flush          = ex_take;

  // ===========================================================================
  // Waveform helpers: the pipeline registers are packed structs, which dump
  // as one wide vector. These named copies make GTKWave readable
  // (see sim/pipeline.gtkw). They drive nothing and are optimised out of
  // non-traced builds.
  // ===========================================================================
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] dbg_if_pc,  dbg_id_pc,  dbg_ex_pc,  dbg_mem_pc,  dbg_wb_pc;
  logic [31:0] dbg_id_insn, dbg_ex_insn, dbg_mem_insn, dbg_wb_insn;
  logic        dbg_id_valid, dbg_ex_valid, dbg_mem_valid, dbg_wb_valid;
  logic [4:0]  dbg_ex_rs1, dbg_ex_rs2, dbg_mem_rd, dbg_wb_rd;
  logic [31:0] dbg_mem_result;
  /* verilator lint_on UNUSEDSIGNAL */

  assign dbg_if_pc      = pc;
  assign dbg_id_pc      = if_id.pc;
  assign dbg_id_insn    = if_id.insn;
  assign dbg_id_valid   = if_id.valid;
  assign dbg_ex_pc      = id_ex.pc;
  assign dbg_ex_insn    = id_ex.insn;
  assign dbg_ex_valid   = id_ex.valid;
  assign dbg_ex_rs1     = id_ex.rs1;
  assign dbg_ex_rs2     = id_ex.rs2;
  assign dbg_mem_pc     = ex_mem.pc;
  assign dbg_mem_insn   = ex_mem.insn;
  assign dbg_mem_valid  = ex_mem.valid;
  assign dbg_mem_rd     = ex_mem.rd;
  assign dbg_mem_result = ex_mem.result;
  assign dbg_wb_pc      = mem_wb.pc;
  assign dbg_wb_insn    = mem_wb.insn;
  assign dbg_wb_valid   = mem_wb.valid;
  assign dbg_wb_rd      = mem_wb.rd;

endmodule
