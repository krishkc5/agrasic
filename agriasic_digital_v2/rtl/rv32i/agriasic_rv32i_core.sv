/* 
   Taarana Jammula (tjammula)
   Krishna Karthikeya Chemudupati (krishkc)
 */

`timescale 1ns / 1ns

// registers are 32 bits in RV32
`define REG_SIZE 31:0

// insns are 32 bits in RV32IM
`define INSN_SIZE 31:0

// RV opcodes are 7 bits
`define OPCODE_SIZE 6:0

`ifndef DIVIDER_STAGES
`define DIVIDER_STAGES 8
`endif

`ifndef SYNTHESIS
`include "RvDisassembler.sv"
`endif
`include "agriasic_rv32i_cla.sv"
`include "agriasic_rv32i_divider.sv"
`include "cycle_status.sv"

module Disasm #(
    byte PREFIX = "D"
) (
    input wire [31:0] insn,
    output wire [(8*32)-1:0] disasm
);
`ifndef SYNTHESIS
  // this code is only for simulation, not synthesis
  string disasm_string;
  always_comb begin
    disasm_string = rv_disasm(insn);
  end
  // HACK: get disasm_string to appear in GtkWave, which can apparently show only wire/logic. Also,
  // string needs to be reversed to render correctly.
  genvar i;
  for (i = 3; i < 32; i = i + 1) begin : gen_disasm
    assign disasm[((i+1-3)*8)-1-:8] = disasm_string[31-i];
  end
  assign disasm[255-:8] = PREFIX;
  assign disasm[247-:8] = ":";
  assign disasm[239-:8] = " ";
`endif
endmodule

module RegFile (
    input logic [4:0] rd,
    input logic [`REG_SIZE] rd_data,
    input logic [4:0] rs1,
    output logic [`REG_SIZE] rs1_data,
    input logic [4:0] rs2,
    output logic [`REG_SIZE] rs2_data,

    input logic clk,
    input logic we,
    input logic rst
);
  localparam int NumRegs = 32;
  logic [`REG_SIZE] regs[NumRegs];

  assign rs1_data = (we && rd == rs1 && rd != 5'd0) ? rd_data : regs[rs1];
  assign rs2_data = (we && rd == rs2 && rd != 5'd0) ? rd_data : regs[rs2];

  // Write to register file
  always_ff @(posedge clk) begin
    if (rst) begin
      // Reset all registers to zero
      for (int i = 0; i < NumRegs; i = i + 1) begin
        regs[i] <= 32'd0;
      end
    end else if (we && rd != 5'd0) begin
      regs[rd] <= rd_data;
    end
  end

endmodule

/** state at the start of Decode stage */
typedef struct packed {
  logic [`REG_SIZE] pc;
  // The instruction itself is NOT held here. The instruction SRAM's own output
  // register serves as the Fetch/Decode pipeline register, so the bits arrive
  // on insn_from_imem during this stage. This flag says whether they are valid
  // (they are not, immediately after reset or a flush).
  logic insn_valid;
  cycle_status_e cycle_status;
} stage_decode_t;

/** state at the start of Execute stage */
typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;

  logic [4:0] rd;
  logic [4:0] rs1;
  logic [4:0] rs2;
  logic [`REG_SIZE] rs1_data;
  logic [`REG_SIZE] rs2_data;

  logic [`REG_SIZE] imm_i_sext;
  logic [`REG_SIZE] imm_s_sext;
  logic [`REG_SIZE] imm_b_sext;
  logic [`REG_SIZE] imm_j_sext;

  logic [6:0] insn_opcode;
} stage_execute_t;

/** state at the start of Memory stage */
typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;

  logic [4:0] rd;
  logic [4:0] rs1;
  logic [4:0] rs2;
  logic [`REG_SIZE] rs2_data;
  logic [`REG_SIZE] rd_data;
  logic rd_we;
  logic [6:0] insn_opcode;
  logic [`REG_SIZE] mem_addr;
  logic is_load;             
  logic is_store;            
  logic halt;                
} stage_memory_t;

/** state at the start of Writeback stage */
typedef struct packed {
  logic [`REG_SIZE] pc;
  logic [`INSN_SIZE] insn;
  cycle_status_e cycle_status;

  logic [4:0] rd;
  logic [`REG_SIZE] rd_data;
  logic rd_we;              
  logic halt;               

  // Added for the synchronous-SRAM data path: load results arrive in Writeback,
  // so byte extraction happens here and needs the load type and byte offset.
  logic is_load;
  logic [1:0] mem_addr_lsb;
} stage_writeback_t;

module DatapathPipelined (
    input wire clk,
    input wire rst,
    output logic [`REG_SIZE] pc_to_imem,
    input wire [`INSN_SIZE] insn_from_imem,
    // dmem is read/write
    output logic [`REG_SIZE] addr_to_dmem,
    input wire [`REG_SIZE] load_data_from_dmem,
    output logic [`REG_SIZE] store_data_to_dmem,
    output logic [3:0] store_we_to_dmem,

    // Memory enables for the synchronous SRAM macros.
    //   imem_ce_o: low while Decode stalls, so the instruction SRAM holds its
    //              output register instead of overwriting the held instruction.
    //   mem_read_en_o: asserted only for real loads, so the data SRAM is not
    //              clocked every cycle. Matters for a power-constrained node.
    output logic imem_ce_o,
    output logic mem_read_en_o,

    output logic halt,

    // The PC of the insn currently in Writeback. 0 if not a valid insn.
    output logic [`REG_SIZE] trace_completed_pc,
    // The bits of the insn currently in Writeback. 0 if not a valid insn.
    output logic [`INSN_SIZE] trace_completed_insn,
    // The status of the insn (or stall) currently in Writeback. See the cycle_status.sv file for valid values.
    output cycle_status_e trace_completed_cycle_status,
    // Backward-compatible aliases used by FPGA system tops.
    output logic [`REG_SIZE] trace_writeback_pc,
    output logic [`INSN_SIZE] trace_writeback_insn,
    output cycle_status_e trace_writeback_cycle_status
);

  // opcodes - see section 19 of RiscV spec
  localparam bit [`OPCODE_SIZE] OpcodeLoad = 7'b00_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeStore = 7'b01_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeBranch = 7'b11_000_11;
  localparam bit [`OPCODE_SIZE] OpcodeJalr = 7'b11_001_11;
  localparam bit [`OPCODE_SIZE] OpcodeMiscMem = 7'b00_011_11;
  localparam bit [`OPCODE_SIZE] OpcodeJal = 7'b11_011_11;

  localparam bit [`OPCODE_SIZE] OpcodeRegImm = 7'b00_100_11;
  localparam bit [`OPCODE_SIZE] OpcodeRegReg = 7'b01_100_11;
  localparam bit [`OPCODE_SIZE] OpcodeEnviron = 7'b11_100_11;

  localparam bit [`OPCODE_SIZE] OpcodeAuipc = 7'b00_101_11;
  localparam bit [`OPCODE_SIZE] OpcodeLui = 7'b01_101_11;

  // cycle counter, not really part of any stage but useful for orienting within GtkWave
  // do not rename this as the testbench uses this value
  logic [`REG_SIZE] cycles_current;
  always_ff @(posedge clk) begin
    if (rst) begin
      cycles_current <= 0;
    end else begin
      cycles_current <= cycles_current + 1;
    end
  end

  /***************/
  /* FETCH STAGE */
  /***************/

  logic [`REG_SIZE] f_pc_current;
  cycle_status_e f_cycle_status;

  logic x_branch_taken;
  logic [`REG_SIZE] x_branch_target;
  logic x_pc_redirect;
  logic [`REG_SIZE] x_next_pc;
  logic decode_stall;

  logic [`REG_SIZE] f_pc_next;
  always_comb begin
    if (x_pc_redirect) begin
      f_pc_next = x_next_pc;
    end else if (decode_stall) begin
      f_pc_next = f_pc_current;
    end else begin
      f_pc_next = f_pc_current + 4;
    end
  end

  // program counter
  always_ff @(posedge clk) begin
    if (rst) begin
      f_pc_current <= 32'd0;
      // NB: use CYCLE_NO_STALL since this is the value that will persist after the last reset cycle
      f_cycle_status <= CYCLE_NO_STALL;
    end else begin
      f_cycle_status <= CYCLE_NO_STALL;
      f_pc_current <= f_pc_next;
    end
  end
  // Send PC to imem. The SRAM captures this address at the end of this cycle
  // and presents the instruction during the following (Decode) cycle. Fetch
  // therefore has only a PC in flight, never an instruction.
  assign pc_to_imem = f_pc_current;

  // Hold the SRAM output while Decode is stalled so the held instruction is not
  // overwritten by a new fetch.
  assign imem_ce_o = !decode_stall;

  // Here's how to disassemble an insn into a string you can view in GtkWave.
  // Use PREFIX to provide a 1-character tag to identify which stage the insn comes from.

  /****************/
  /* DECODE STAGE */
  /****************/

  // this shows how to package up state in a `struct packed`, and how to pass it between stages
  stage_decode_t decode_state;
  always_ff @(posedge clk) begin
    if (rst) begin
      decode_state <= '{
        pc: 0,
        insn_valid: 1'b0,
        cycle_status: CYCLE_RESET
      };
    end else if (x_pc_redirect) begin
      decode_state <= '{
        pc: 0,
        insn_valid: 1'b0,
        cycle_status: CYCLE_TAKEN_BRANCH
      };
    end else if (decode_stall) begin
      decode_state <= decode_state;
    end else begin
      decode_state <= '{
        pc: f_pc_current,
        insn_valid: 1'b1,
        cycle_status: f_cycle_status
      };
    end
  end
  wire [255:0] d_disasm;
  Disasm #(
      .PREFIX("D")
  ) disasm_1decode (
      .insn  (d_insn),
      .disasm(d_disasm)
  );

  // The instruction for this stage comes straight off the SRAM output register.
  // Masked to zero when the slot is invalid, preserving the previous behavior
  // where a flushed or reset Decode slot carried insn == 0.
  wire [`INSN_SIZE] d_insn = decode_state.insn_valid ? insn_from_imem : 32'd0;

  wire [6:0] d_insn_funct7 = d_insn[31:25];
  wire [4:0] d_insn_rs2 = d_insn[24:20];
  wire [4:0] d_insn_rs1 = d_insn[19:15];
  wire [2:0] d_insn_funct3 = d_insn[14:12];
  wire [4:0] d_insn_rd = d_insn[11:7];
  wire [6:0] d_insn_opcode = d_insn[6:0];

  // I-type
  wire [11:0] d_imm_i = d_insn[31:20];
  wire [`REG_SIZE] d_imm_i_sext = {{20{d_imm_i[11]}}, d_imm_i};

  // S-type
  wire [11:0] d_imm_s;
  assign d_imm_s[11:5] = d_insn_funct7;
  assign d_imm_s[4:0] = d_insn_rd;
  wire [`REG_SIZE] d_imm_s_sext = {{20{d_imm_s[11]}}, d_imm_s};

  // B-type
  wire [12:0] d_imm_b;
  assign {d_imm_b[12], d_imm_b[10:5]} = d_insn_funct7;
  assign {d_imm_b[4:1], d_imm_b[11]} = d_insn_rd;
  assign d_imm_b[0] = 1'b0;
  wire [`REG_SIZE] d_imm_b_sext = {{19{d_imm_b[12]}}, d_imm_b};

  // J-type
  wire [20:0] d_imm_j;
  assign {d_imm_j[20], d_imm_j[10:1], d_imm_j[11], d_imm_j[19:12], d_imm_j[0]} =
         {d_insn[31:12], 1'b0};
  wire [`REG_SIZE] d_imm_j_sext = {{11{d_imm_j[20]}}, d_imm_j};

  // Register file
  wire [`REG_SIZE] d_rs1_data;
  wire [`REG_SIZE] d_rs2_data;

  logic [`REG_SIZE] w_rd_data;
  logic [4:0] w_rd;
  logic w_rd_we;

  RegFile rf (
    .clk(clk),
    .rst(rst),
    .we(w_rd_we),
    .rd(w_rd),
    .rd_data(w_rd_data),
    .rs1(d_insn_rs1),
    .rs2(d_insn_rs2),
    .rs1_data(d_rs1_data),
    .rs2_data(d_rs2_data)
  );

  /*****************/
  /* EXECUTE STAGE */
  /*****************/

  stage_execute_t execute_state;

  wire x_is_load_insn = execute_state.insn_opcode == OpcodeLoad;
  wire d_uses_x_rd_rs1 = (d_insn_rs1 == execute_state.rd) && (execute_state.rd != 5'd0);
  wire d_uses_x_rd_rs2 = (d_insn_rs2 == execute_state.rd) && (execute_state.rd != 5'd0);

  wire d_is_lui = d_insn_opcode == OpcodeLui;
  wire d_is_auipc = d_insn_opcode == OpcodeAuipc;
  wire d_is_jal = d_insn_opcode == OpcodeJal;
  wire d_is_mul_insn = d_insn_opcode == OpcodeRegReg &&
                       d_insn_funct7 == 7'd1 &&
                       !d_insn_funct3[2];
  wire d_is_div_insn = d_insn_opcode == OpcodeRegReg &&
                       d_insn_funct7 == 7'd1 &&
                       d_insn_funct3[2];
  wire d_uses_rs1 = !(d_is_lui || d_is_auipc || d_is_jal);
  wire d_uses_rs2 = (d_insn_opcode == OpcodeRegReg) ||
                    (d_insn_opcode == OpcodeBranch) ||
                    (d_insn_opcode == OpcodeStore);

  wire d_uses_rs2_for_load_use = (d_insn_opcode == OpcodeRegReg) ||
                                 (d_insn_opcode == OpcodeBranch);

  wire d_uses_m_rd_rs1 = (d_insn_rs1 == memory_state.rd) && (memory_state.rd != 5'd0);
  wire d_uses_m_rd_rs2 = (d_insn_rs2 == memory_state.rd) && (memory_state.rd != 5'd0);

  // Synchronous-SRAM load latency.
  //
  // Load data is not available for forwarding until Writeback, so a dependent
  // instruction is held in Decode while the producing load is in EITHER Execute
  // or Memory. Once the load reaches Writeback, the WX bypass supplies it.
  //
  //   distance 1  (load; use)         -> 2 stall cycles
  //   distance 2  (load; filler; use) -> 1 stall cycle
  //   distance 3+                     -> no stall
  //
  // This pairs with mx_bypass_rs*, which now excludes loads. Both changes must
  // stay together: relaxing the stall without restoring an M-stage forward
  // would read a stale register value.
  wire m_is_load_insn = memory_state.is_load && memory_state.rd_we;

  wire load_use_hazard = (x_is_load_insn &&
                          ((d_uses_rs1 && d_uses_x_rd_rs1) ||
                           (d_uses_rs2_for_load_use && d_uses_x_rd_rs2))) ||
                         (m_is_load_insn &&
                          ((d_uses_rs1 && d_uses_m_rd_rs1) ||
                           (d_uses_rs2_for_load_use && d_uses_m_rd_rs2)));

  // Divider MX bypass intentionally excludes load data to shorten critical path.
  wire div_load_m_hazard = d_is_div_insn &&
                           memory_state.is_load &&
                           memory_state.rd_we &&
                           ((d_uses_rs1 && d_uses_m_rd_rs1) ||
                            (d_uses_rs2 && d_uses_m_rd_rs2));
  wire mul_load_m_hazard = d_is_mul_insn &&
                           memory_state.is_load &&
                           memory_state.rd_we &&
                           ((d_uses_rs1 && d_uses_m_rd_rs1) ||
                            (d_uses_rs2 && d_uses_m_rd_rs2));


  logic div_stall;

  assign decode_stall = load_use_hazard || div_load_m_hazard || mul_load_m_hazard || div_stall;

  always_ff @(posedge clk) begin
    if (rst) begin
      execute_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_RESET,
        rd: 0,
        rs1: 0,
        rs2: 0,
        rs1_data: 0,
        rs2_data: 0,
        imm_i_sext: 0,
        imm_s_sext: 0,
        imm_b_sext: 0,
        imm_j_sext: 0,
        insn_opcode: 0
      };
    end else if (x_pc_redirect) begin
      execute_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_TAKEN_BRANCH,
        rd: 0,
        rs1: 0,
        rs2: 0,
        rs1_data: 0,
        rs2_data: 0,
        imm_i_sext: 0,
        imm_s_sext: 0,
        imm_b_sext: 0,
        imm_j_sext: 0,
        insn_opcode: 0
      };
    end else if (div_stall) begin
      execute_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_DIV,
        rd: 0,
        rs1: 0,
        rs2: 0,
        rs1_data: 0,
        rs2_data: 0,
        imm_i_sext: 0,
        imm_s_sext: 0,
        imm_b_sext: 0,
        imm_j_sext: 0,
        insn_opcode: 0
      };
    end else if (load_use_hazard) begin
      execute_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_LOAD2USE,
        rd: 0,
        rs1: 0,
        rs2: 0,
        rs1_data: 0,
        rs2_data: 0,
        imm_i_sext: 0,
        imm_s_sext: 0,
        imm_b_sext: 0,
        imm_j_sext: 0,
        insn_opcode: 0
      };
    end else begin
      execute_state <= '{
        pc: decode_state.pc,
        insn: d_insn,
        cycle_status: decode_state.cycle_status,
        rd: d_insn_rd,
        rs1: d_insn_rs1,
        rs2: d_insn_rs2,
        rs1_data: d_rs1_data,
        rs2_data: d_rs2_data,
        imm_i_sext: d_imm_i_sext,
        imm_s_sext: d_imm_s_sext,
        imm_b_sext: d_imm_b_sext,
        imm_j_sext: d_imm_j_sext,
        insn_opcode: d_insn_opcode
      };
    end
  end

  wire [255:0] x_disasm;
  Disasm #(
      .PREFIX("X")
  ) disasm_2execute (
      .insn  (execute_state.insn),
      .disasm(x_disasm)
  );

  wire x_insn_lui   = execute_state.insn_opcode == OpcodeLui;
  wire x_insn_auipc = execute_state.insn_opcode == OpcodeAuipc;
  wire x_insn_jal   = execute_state.insn_opcode == OpcodeJal;
  wire x_insn_jalr  = execute_state.insn_opcode == OpcodeJalr;
  wire x_insn_branch = execute_state.insn_opcode == OpcodeBranch;
  wire x_insn_load  = execute_state.insn_opcode == OpcodeLoad;
  wire x_insn_store = execute_state.insn_opcode == OpcodeStore;
  wire x_insn_regimm = execute_state.insn_opcode == OpcodeRegImm;
  wire x_insn_regreg = execute_state.insn_opcode == OpcodeRegReg;
  wire x_insn_environ = execute_state.insn_opcode == OpcodeEnviron;
  wire x_insn_fence = execute_state.insn_opcode == OpcodeMiscMem;

  wire [2:0] x_insn_funct3 = execute_state.insn[14:12];
  wire [6:0] x_insn_funct7 = execute_state.insn[31:25];
  wire [4:0] x_insn_shamt = execute_state.insn[24:20];

  wire x_is_beq  = x_insn_branch && x_insn_funct3 == 3'b000;
  wire x_is_bne  = x_insn_branch && x_insn_funct3 == 3'b001;
  wire x_is_blt  = x_insn_branch && x_insn_funct3 == 3'b100;
  wire x_is_bge  = x_insn_branch && x_insn_funct3 == 3'b101;
  wire x_is_bltu = x_insn_branch && x_insn_funct3 == 3'b110;
  wire x_is_bgeu = x_insn_branch && x_insn_funct3 == 3'b111;

  wire x_is_addi  = x_insn_regimm && x_insn_funct3 == 3'b000;
  wire x_is_slti  = x_insn_regimm && x_insn_funct3 == 3'b010;
  wire x_is_sltiu = x_insn_regimm && x_insn_funct3 == 3'b011;
  wire x_is_xori  = x_insn_regimm && x_insn_funct3 == 3'b100;
  wire x_is_ori   = x_insn_regimm && x_insn_funct3 == 3'b110;
  wire x_is_andi  = x_insn_regimm && x_insn_funct3 == 3'b111;
  wire x_is_slli  = x_insn_regimm && x_insn_funct3 == 3'b001 && x_insn_funct7 == 7'd0;
  wire x_is_srli  = x_insn_regimm && x_insn_funct3 == 3'b101 && x_insn_funct7 == 7'd0;
  wire x_is_srai  = x_insn_regimm && x_insn_funct3 == 3'b101 && x_insn_funct7 == 7'b0100000;

  wire x_is_add  = x_insn_regreg && x_insn_funct3 == 3'b000 && x_insn_funct7 == 7'd0;
  wire x_is_sub  = x_insn_regreg && x_insn_funct3 == 3'b000 && x_insn_funct7 == 7'b0100000;
  wire x_is_sll  = x_insn_regreg && x_insn_funct3 == 3'b001 && x_insn_funct7 == 7'd0;
  wire x_is_slt  = x_insn_regreg && x_insn_funct3 == 3'b010 && x_insn_funct7 == 7'd0;
  wire x_is_sltu = x_insn_regreg && x_insn_funct3 == 3'b011 && x_insn_funct7 == 7'd0;
  wire x_is_xor  = x_insn_regreg && x_insn_funct3 == 3'b100 && x_insn_funct7 == 7'd0;
  wire x_is_srl  = x_insn_regreg && x_insn_funct3 == 3'b101 && x_insn_funct7 == 7'd0;
  wire x_is_sra  = x_insn_regreg && x_insn_funct3 == 3'b101 && x_insn_funct7 == 7'b0100000;
  wire x_is_or   = x_insn_regreg && x_insn_funct3 == 3'b110 && x_insn_funct7 == 7'd0;
  wire x_is_and  = x_insn_regreg && x_insn_funct3 == 3'b111 && x_insn_funct7 == 7'd0;

  wire x_is_mul    = x_insn_regreg && x_insn_funct7 == 7'd1 && x_insn_funct3 == 3'b000;
  wire x_is_mulh   = x_insn_regreg && x_insn_funct7 == 7'd1 && x_insn_funct3 == 3'b001;
  wire x_is_mulhsu = x_insn_regreg && x_insn_funct7 == 7'd1 && x_insn_funct3 == 3'b010;
  wire x_is_mulhu  = x_insn_regreg && x_insn_funct7 == 7'd1 && x_insn_funct3 == 3'b011;
  wire x_is_div    = x_insn_regreg && x_insn_funct7 == 7'd1 && x_insn_funct3 == 3'b100;
  wire x_is_divu   = x_insn_regreg && x_insn_funct7 == 7'd1 && x_insn_funct3 == 3'b101;
  wire x_is_rem    = x_insn_regreg && x_insn_funct7 == 7'd1 && x_insn_funct3 == 3'b110;
  wire x_is_remu   = x_insn_regreg && x_insn_funct7 == 7'd1 && x_insn_funct3 == 3'b111;

  wire x_is_ecall = x_insn_environ && execute_state.insn[31:7] == 25'd0;



  // Get operand values with bypassing
  logic [`REG_SIZE] x_rs1_val;
  logic [`REG_SIZE] x_rs2_val;
  logic [`REG_SIZE] x_div_rs1_val;
  logic [`REG_SIZE] x_div_rs2_val;
  logic [`REG_SIZE] x_mul_rs1_val;
  logic [`REG_SIZE] x_mul_rs2_val;

  // MX bypass conditions
  // Loads are excluded: with a synchronous SRAM the data has not returned yet
  // during Memory. A dependent instruction is held in Decode by load_use_hazard
  // until the load reaches Writeback, where it is forwarded WX instead.
  wire mx_bypass_rs1 = memory_state.rd_we &&
                       !memory_state.is_load &&
                       (memory_state.rd == execute_state.rs1) &&
                       (execute_state.rs1 != 5'd0);
  wire mx_bypass_rs2 = memory_state.rd_we &&
                       !memory_state.is_load &&
                       (memory_state.rd == execute_state.rs2) &&
                       (execute_state.rs2 != 5'd0);
  wire mx_div_bypass_rs1 = memory_state.rd_we &&
                           !memory_state.is_load &&
                           (memory_state.rd == execute_state.rs1) &&
                           (execute_state.rs1 != 5'd0);
  wire mx_div_bypass_rs2 = memory_state.rd_we &&
                           !memory_state.is_load &&
                           (memory_state.rd == execute_state.rs2) &&
                           (execute_state.rs2 != 5'd0);
  wire mx_mul_bypass_rs1 = memory_state.rd_we &&
                           !memory_state.is_load &&
                           (memory_state.rd == execute_state.rs1) &&
                           (execute_state.rs1 != 5'd0);
  wire mx_mul_bypass_rs2 = memory_state.rd_we &&
                           !memory_state.is_load &&
                           (memory_state.rd == execute_state.rs2) &&
                           (execute_state.rs2 != 5'd0);

  // WX bypass conditions
  wire wx_bypass_rs1 = writeback_state.rd_we &&
                       (writeback_state.rd == execute_state.rs1) &&
                       (execute_state.rs1 != 5'd0) &&
                       !mx_bypass_rs1;
  wire wx_bypass_rs2 = writeback_state.rd_we &&
                       (writeback_state.rd == execute_state.rs2) &&
                       (execute_state.rs2 != 5'd0) &&
                       !mx_bypass_rs2;
  wire wx_mul_bypass_rs1 = writeback_state.rd_we &&
                           (writeback_state.rd == execute_state.rs1) &&
                           (execute_state.rs1 != 5'd0) &&
                           !mx_mul_bypass_rs1;
  wire wx_mul_bypass_rs2 = writeback_state.rd_we &&
                           (writeback_state.rd == execute_state.rs2) &&
                           (execute_state.rs2 != 5'd0) &&
                           !mx_mul_bypass_rs2;

  always_comb begin
    if (mx_bypass_rs1)
      x_rs1_val = memory_state.rd_data;
    else if (wx_bypass_rs1)
      x_rs1_val = w_rd_data;
    else
      x_rs1_val = execute_state.rs1_data;
  end

  always_comb begin
    if (mx_bypass_rs2)
      x_rs2_val = memory_state.rd_data;
    else if (wx_bypass_rs2)
      x_rs2_val = w_rd_data;
    else
      x_rs2_val = execute_state.rs2_data;
  end

  // Keep dedicated bypass muxes for divider operands to reduce coupling with ALU timing.
  always_comb begin
    if (mx_div_bypass_rs1)
      x_div_rs1_val = memory_state.rd_data;
    else if (wx_bypass_rs1)
      x_div_rs1_val = w_rd_data;
    else
      x_div_rs1_val = execute_state.rs1_data;
  end

  always_comb begin
    if (mx_div_bypass_rs2)
      x_div_rs2_val = memory_state.rd_data;
    else if (wx_bypass_rs2)
      x_div_rs2_val = w_rd_data;
    else
      x_div_rs2_val = execute_state.rs2_data;
  end

  // Keep dedicated bypass muxes for multiplier operands to avoid BRAM->MUL critical paths.
  always_comb begin
    if (mx_mul_bypass_rs1)
      x_mul_rs1_val = memory_state.rd_data;
    else if (wx_mul_bypass_rs1)
      x_mul_rs1_val = w_rd_data;
    else
      x_mul_rs1_val = execute_state.rs1_data;
  end

  always_comb begin
    if (mx_mul_bypass_rs2)
      x_mul_rs2_val = memory_state.rd_data;
    else if (wx_mul_bypass_rs2)
      x_mul_rs2_val = w_rd_data;
    else
      x_mul_rs2_val = execute_state.rs2_data;
  end

  wire [`REG_SIZE] x_cla_a = x_rs1_val;
  wire [`REG_SIZE] x_cla_b_raw = x_is_sub ? ~x_rs2_val :
                                  (x_insn_regimm ? execute_state.imm_i_sext : x_rs2_val);
  wire x_cla_cin = x_is_sub;
  wire [`REG_SIZE] x_cla_sum;

  CarryLookaheadAdder cla_alu (
    .a(x_cla_a),
    .b(x_cla_b_raw),
    .cin(x_cla_cin),
    .sum(x_cla_sum)
  );

  wire [`REG_SIZE] x_mem_addr;
  wire [`REG_SIZE] x_mem_imm = x_insn_store ? execute_state.imm_s_sext : execute_state.imm_i_sext;
  CarryLookaheadAdder cla_mem (
    .a(x_rs1_val),
    .b(x_mem_imm),
    .cin(1'b0),
    .sum(x_mem_addr)
  );

  localparam int DivLatency = `DIVIDER_STAGES;
  localparam int DivResultStage = DivLatency - 2;

  typedef struct packed {
    logic valid;
    logic [`REG_SIZE] pc;
    logic [`INSN_SIZE] insn;
    cycle_status_e cycle_status;
    logic [4:0] rd;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [`REG_SIZE] rs1_val;
    logic [`REG_SIZE] rs2_val;
    logic is_signed;
    logic is_rem;
  } div_pipe_entry_t;

  div_pipe_entry_t div_pipe[DivLatency];

  wire x_is_div_insn = x_is_div || x_is_divu || x_is_rem || x_is_remu;
  wire x_div_is_signed = x_is_div || x_is_rem;
  wire x_div_is_rem = x_is_rem || x_is_remu;

  logic [`REG_SIZE] div_dividend;
  logic [`REG_SIZE] div_divisor;
  wire [`REG_SIZE] div_abs_rs1 = x_div_rs1_val[31] ? (~x_div_rs1_val + 32'd1) : x_div_rs1_val;
  wire [`REG_SIZE] div_abs_rs2 = x_div_rs2_val[31] ? (~x_div_rs2_val + 32'd1) : x_div_rs2_val;
  always_comb begin
    if (x_div_is_signed) begin
      div_dividend = div_abs_rs1;
      div_divisor = div_abs_rs2;
    end else begin
      div_dividend = x_div_rs1_val;
      div_divisor = x_div_rs2_val;
    end
  end

  wire [`REG_SIZE] div_quotient;
  wire [`REG_SIZE] div_remainder;

  DividerUnsignedPipelined divider (
    .clk(clk),
    .rst(rst),
    .stall(1'b0),
    .i_dividend(div_dividend),
    .i_divisor(div_divisor),
    .o_quotient(div_quotient),
    .o_remainder(div_remainder)
  );

  div_pipe_entry_t div_issue_entry;
  always_comb begin
    div_issue_entry = '0;
    if (x_is_div_insn) begin
      div_issue_entry.valid = 1'b1;
      div_issue_entry.pc = execute_state.pc;
      div_issue_entry.insn = execute_state.insn;
      div_issue_entry.cycle_status = execute_state.cycle_status;
      div_issue_entry.rd = execute_state.rd;
      div_issue_entry.rs1 = execute_state.rs1;
      div_issue_entry.rs2 = execute_state.rs2;
      div_issue_entry.rs1_val = x_div_rs1_val;
      div_issue_entry.rs2_val = x_div_rs2_val;
      div_issue_entry.is_signed = x_div_is_signed;
      div_issue_entry.is_rem = x_div_is_rem;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < DivLatency; i = i + 1) begin
        div_pipe[i] <= '0;
      end
    end else begin
      div_pipe[0] <= div_issue_entry;
      for (int i = 1; i < DivLatency; i = i + 1) begin
        div_pipe[i] <= div_pipe[i-1];
      end
    end
  end

  logic div_unresolved;
  logic d_depends_on_pending_div;
  always_comb begin
    div_unresolved = x_is_div_insn;
    d_depends_on_pending_div = 1'b0;

    if (x_is_div_insn && execute_state.rd != 5'd0 &&
        ((d_uses_rs1 && d_insn_rs1 == execute_state.rd) ||
         (d_uses_rs2 && d_insn_rs2 == execute_state.rd))) begin
      d_depends_on_pending_div = 1'b1;
    end

    for (int i = 0; i < DivResultStage; i = i + 1) begin
      div_unresolved = div_unresolved || div_pipe[i].valid;
      if (div_pipe[i].valid && div_pipe[i].rd != 5'd0 &&
          ((d_uses_rs1 && d_insn_rs1 == div_pipe[i].rd) ||
           (d_uses_rs2 && d_insn_rs2 == div_pipe[i].rd))) begin
        d_depends_on_pending_div = 1'b1;
      end
    end
  end

  assign div_stall = (div_unresolved && !d_is_div_insn) ||
                     (d_is_div_insn && d_depends_on_pending_div);

  wire div_result_valid = div_pipe[DivResultStage].valid;
  wire [`REG_SIZE] div_result_rs1 = div_pipe[DivResultStage].rs1_val;
  wire [`REG_SIZE] div_result_rs2 = div_pipe[DivResultStage].rs2_val;
  wire div_result_is_signed = div_pipe[DivResultStage].is_signed;
  wire div_result_is_rem = div_pipe[DivResultStage].is_rem;

  logic [`REG_SIZE] div_result_data;
  always_comb begin
    div_result_data = 32'd0;
    if (div_result_is_rem) begin
      if (div_result_rs2 == 32'd0) begin
        div_result_data = div_result_rs1;
      end else if (div_result_is_signed &&
                   div_result_rs1 == 32'h80000000 &&
                   div_result_rs2 == 32'hFFFFFFFF) begin
        div_result_data = 32'd0;
      end else if (div_result_is_signed) begin
        div_result_data = div_result_rs1[31] ? (~div_remainder + 32'd1) : div_remainder;
      end else begin
        div_result_data = div_remainder;
      end
    end else begin
      if (div_result_rs2 == 32'd0) begin
        div_result_data = 32'hFFFFFFFF;
      end else if (div_result_is_signed &&
                   div_result_rs1 == 32'h80000000 &&
                   div_result_rs2 == 32'hFFFFFFFF) begin
        div_result_data = 32'h80000000;
      end else if (div_result_is_signed) begin
        div_result_data = (div_result_rs1[31] ^ div_result_rs2[31]) ? (~div_quotient + 32'd1) : div_quotient;
      end else begin
        div_result_data = div_quotient;
      end
    end
  end

  logic x_branch_cond;
  always_comb begin
    x_branch_cond = 1'b0;
    case (1'b1)
      x_is_beq:  x_branch_cond = (x_rs1_val == x_rs2_val);
      x_is_bne:  x_branch_cond = (x_rs1_val != x_rs2_val);
      x_is_blt:  x_branch_cond = ($signed(x_rs1_val) < $signed(x_rs2_val));
      x_is_bge:  x_branch_cond = ($signed(x_rs1_val) >= $signed(x_rs2_val));
      x_is_bltu: x_branch_cond = (x_rs1_val < x_rs2_val);
      x_is_bgeu: x_branch_cond = (x_rs1_val >= x_rs2_val);
      default:   x_branch_cond = 1'b0;
    endcase
  end
  assign x_branch_taken = x_insn_branch && x_branch_cond;

  wire [`REG_SIZE] x_branch_target_raw = execute_state.pc + execute_state.imm_b_sext;
  wire [`REG_SIZE] x_jal_target = execute_state.pc + execute_state.imm_j_sext;
  wire [`REG_SIZE] x_jalr_target = (x_rs1_val + execute_state.imm_i_sext) & 32'hFFFFFFFE;
  assign x_branch_target = x_branch_target_raw;

  assign x_pc_redirect = x_branch_taken || x_insn_jal || x_insn_jalr;

  always_comb begin
    if (x_insn_jal)
      x_next_pc = x_jal_target;
    else if (x_insn_jalr)
      x_next_pc = x_jalr_target;
    else
      x_next_pc = x_branch_target;
  end

  logic [`REG_SIZE] x_alu_result;
  always_comb begin
    x_alu_result = 32'd0;
    case (1'b1)

      x_insn_lui: x_alu_result = {execute_state.insn[31:12], 12'b0};

      // AUIPC
      x_insn_auipc: x_alu_result = execute_state.pc + {execute_state.insn[31:12], 12'b0};

      // JAL/JALR
      x_insn_jal, x_insn_jalr: x_alu_result = execute_state.pc + 4;

      // Arithmetic
      x_is_add, x_is_addi: x_alu_result = x_cla_sum;
      x_is_sub: x_alu_result = x_cla_sum;

      // Logical
      x_is_and, x_is_andi: x_alu_result = x_rs1_val & (x_is_andi ? execute_state.imm_i_sext : x_rs2_val);
      x_is_or, x_is_ori:   x_alu_result = x_rs1_val | (x_is_ori ? execute_state.imm_i_sext : x_rs2_val);
      x_is_xor, x_is_xori: x_alu_result = x_rs1_val ^ (x_is_xori ? execute_state.imm_i_sext : x_rs2_val);

      // Shifts
      x_is_sll:  x_alu_result = x_rs1_val << x_rs2_val[4:0];
      x_is_slli: x_alu_result = x_rs1_val << x_insn_shamt;
      x_is_srl:  x_alu_result = x_rs1_val >> x_rs2_val[4:0];
      x_is_srli: x_alu_result = x_rs1_val >> x_insn_shamt;
      x_is_sra:  x_alu_result = $signed(x_rs1_val) >>> x_rs2_val[4:0];
      x_is_srai: x_alu_result = $signed(x_rs1_val) >>> x_insn_shamt;

      // Comparisons
      x_is_slt, x_is_slti:   x_alu_result = ($signed(x_rs1_val) < $signed(x_is_slti ? execute_state.imm_i_sext : x_rs2_val)) ? 32'd1 : 32'd0;
      x_is_sltu, x_is_sltiu: x_alu_result = (x_rs1_val < (x_is_sltiu ? execute_state.imm_i_sext : x_rs2_val)) ? 32'd1 : 32'd0;

      // Multiply instructions
      x_is_mul: x_alu_result = x_mul_rs1_val * x_mul_rs2_val;  // Lower 32 bits
      x_is_mulh: begin
        // Signed x Signed, upper 32 bits
        logic signed [63:0] mulh_prod;
        mulh_prod = $signed({{32{x_mul_rs1_val[31]}}, x_mul_rs1_val}) * $signed({{32{x_mul_rs2_val[31]}}, x_mul_rs2_val});
        x_alu_result = mulh_prod[63:32];
      end
      x_is_mulhsu: begin
        // Signed x Unsigned, upper 32 bits
        logic signed [63:0] mulhsu_prod;
        mulhsu_prod = $signed({{32{x_mul_rs1_val[31]}}, x_mul_rs1_val}) * $signed({1'b0, {31'b0, x_mul_rs2_val}});
        x_alu_result = mulhsu_prod[63:32];
      end
      x_is_mulhu: begin
        // Unsigned x Unsigned, upper 32 bits
        logic [63:0] mulhu_prod;
        mulhu_prod = {32'b0, x_mul_rs1_val} * {32'b0, x_mul_rs2_val};
        x_alu_result = mulhu_prod[63:32];
      end

      x_is_div, x_is_divu, x_is_rem, x_is_remu: x_alu_result = 32'd0;

      default: x_alu_result = 32'd0;
    endcase
  end

  wire x_rd_we = (x_insn_lui || x_insn_regimm || x_insn_regreg || x_insn_load ||
                  x_insn_jal || x_insn_jalr || x_insn_auipc) &&
                 (execute_state.rd != 5'd0);

  /****************/
  /* MEMORY STAGE */
  /****************/

  // Pipeline register
  stage_memory_t memory_state;

  always_ff @(posedge clk) begin
    if (rst) begin
      memory_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_RESET,
        rd: 0,
        rs1: 0,
        rs2: 0,
        rs2_data: 0,
        rd_data: 0,
        rd_we: 0,
        insn_opcode: 0,
        mem_addr: 0,
        is_load: 0,
        is_store: 0,
        halt: 0
      };
    end else if (div_result_valid) begin
      memory_state <= '{
        pc: div_pipe[DivResultStage].pc,
        insn: div_pipe[DivResultStage].insn,
        cycle_status: div_pipe[DivResultStage].cycle_status,
        rd: div_pipe[DivResultStage].rd,
        rs1: div_pipe[DivResultStage].rs1,
        rs2: div_pipe[DivResultStage].rs2,
        rs2_data: 0,
        rd_data: div_result_data,
        rd_we: div_pipe[DivResultStage].rd != 5'd0,
        insn_opcode: OpcodeRegReg,
        mem_addr: 0,
        is_load: 0,
        is_store: 0,
        halt: 0
      };
    end else if (x_is_div_insn) begin
      memory_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_DIV,
        rd: 0,
        rs1: 0,
        rs2: 0,
        rs2_data: 0,
        rd_data: 0,
        rd_we: 0,
        insn_opcode: 0,
        mem_addr: 0,
        is_load: 0,
        is_store: 0,
        halt: 0
      };
    end else begin
      memory_state <= '{
        pc: execute_state.pc,
        insn: execute_state.insn,
        cycle_status: execute_state.cycle_status,
        rd: execute_state.rd,
        rs1: execute_state.rs1,
        rs2: execute_state.rs2,
        rs2_data: x_rs2_val,
        rd_data: x_alu_result,
        rd_we: x_rd_we,
        insn_opcode: execute_state.insn_opcode,
        mem_addr: x_mem_addr,
        is_load: x_insn_load,
        is_store: x_insn_store,
        halt: x_is_ecall
      };
    end
  end

  wire [255:0] m_disasm;
  Disasm #(
      .PREFIX("M")
  ) disasm_3memory (
      .insn  (memory_state.insn),
      .disasm(m_disasm)
  );

  wire [2:0] m_insn_funct3 = memory_state.insn[14:12];

  wire m_is_lb  = memory_state.is_load && m_insn_funct3 == 3'b000;
  wire m_is_lh  = memory_state.is_load && m_insn_funct3 == 3'b001;
  wire m_is_lw  = memory_state.is_load && m_insn_funct3 == 3'b010;
  wire m_is_lbu = memory_state.is_load && m_insn_funct3 == 3'b100;
  wire m_is_lhu = memory_state.is_load && m_insn_funct3 == 3'b101;

  // --------------------------------------------------------------------------
  // WM bypass for store data.
  //
  // A store's rs2 is consumed here in Memory, not in Execute, which is why
  // d_uses_rs2_for_load_use deliberately excludes stores from the load-use
  // stall. The original design let the store proceed and picked the value up
  // via MX forwarding of load data. With a synchronous SRAM that forward is
  // gone, so an older load sitting in Writeback must hand its result directly
  // to the store in Memory.
  // --------------------------------------------------------------------------
  wire wm_bypass_rs2 = writeback_state.rd_we &&
                       memory_state.is_store &&
                       (writeback_state.rd == memory_state.rs2) &&
                       (memory_state.rs2 != 5'd0);

  wire [`REG_SIZE] m_rs2_val = wm_bypass_rs2 ? w_rd_data : memory_state.rs2_data;

  wire m_is_sb = memory_state.is_store && m_insn_funct3 == 3'b000;
  wire m_is_sh = memory_state.is_store && m_insn_funct3 == 3'b001;
  wire m_is_sw = memory_state.is_store && m_insn_funct3 == 3'b010;

  assign addr_to_dmem = {memory_state.mem_addr[31:2], 2'b00};

  logic [`REG_SIZE] m_store_data;
  logic [3:0] m_store_we;

  always_comb begin
    m_store_data = 32'd0;
    m_store_we = 4'b0000;

    if (memory_state.is_store) begin
      case (1'b1)
        m_is_sw: begin
          m_store_data = m_rs2_val;
          m_store_we = 4'b1111;
        end
        m_is_sh: begin
          case (memory_state.mem_addr[1])
            1'b0: begin
              m_store_data = {16'b0, m_rs2_val[15:0]};
              m_store_we = 4'b0011;
            end
            1'b1: begin
              m_store_data = {m_rs2_val[15:0], 16'b0};
              m_store_we = 4'b1100;
            end
          endcase
        end
        m_is_sb: begin
          case (memory_state.mem_addr[1:0])
            2'b00: begin
              m_store_data = {24'b0, m_rs2_val[7:0]};
              m_store_we = 4'b0001;
            end
            2'b01: begin
              m_store_data = {16'b0, m_rs2_val[7:0], 8'b0};
              m_store_we = 4'b0010;
            end
            2'b10: begin
              m_store_data = {8'b0, m_rs2_val[7:0], 16'b0};
              m_store_we = 4'b0100;
            end
            2'b11: begin
              m_store_data = {m_rs2_val[7:0], 24'b0};
              m_store_we = 4'b1000;
            end
          endcase
        end
        default: begin
          m_store_data = 32'd0;
          m_store_we = 4'b0000;
        end
      endcase
    end
  end

  assign store_data_to_dmem = m_store_data;
  assign mem_read_en_o = memory_state.is_load;
  assign store_we_to_dmem = m_store_we;

  // NOTE: load byte extraction used to live here, in Memory. With a synchronous
  // SRAM the load data does not return until Writeback, so the extraction mux
  // has moved there. See the Writeback stage below.

  /********************/
  /* WRITEBACK STAGE  */
  /********************/

  stage_writeback_t writeback_state;

  always_ff @(posedge clk) begin
    if (rst) begin
      writeback_state <= '{
        pc: 0,
        insn: 0,
        cycle_status: CYCLE_RESET,
        rd: 0,
        rd_data: 0,
        rd_we: 0,
        halt: 0,
        is_load: 0,
        mem_addr_lsb: 0
      };
    end else begin
      writeback_state <= '{
        pc: memory_state.pc,
        insn: memory_state.insn,
        cycle_status: memory_state.cycle_status,
        rd: memory_state.rd,
        // ALU result only. Load data is muxed in during Writeback once the SRAM
        // has returned it.
        rd_data: memory_state.rd_data,
        rd_we: memory_state.rd_we && !memory_state.is_store,
        halt: memory_state.halt,
        is_load: memory_state.is_load,
        mem_addr_lsb: memory_state.mem_addr[1:0]
      };
    end
  end

  wire [255:0] w_disasm;
  Disasm #(
      .PREFIX("W")
  ) disasm_4writeback (
      .insn  (writeback_state.insn),
      .disasm(w_disasm)
  );

  // --------------------------------------------------------------------------
  // Load byte extraction (moved here from Memory).
  //
  // The synchronous SRAM captures the address during Memory and presents data
  // at the start of Writeback, so sign/zero extension happens in this stage.
  // w_rd_data is combinational within Writeback, which keeps it available for
  // WX forwarding in the same cycle -- the WX bypass path is unchanged.
  // --------------------------------------------------------------------------
  wire [2:0] w_insn_funct3 = writeback_state.insn[14:12];

  wire w_is_lb  = writeback_state.is_load && w_insn_funct3 == 3'b000;
  wire w_is_lh  = writeback_state.is_load && w_insn_funct3 == 3'b001;
  wire w_is_lw  = writeback_state.is_load && w_insn_funct3 == 3'b010;
  wire w_is_lbu = writeback_state.is_load && w_insn_funct3 == 3'b100;
  wire w_is_lhu = writeback_state.is_load && w_insn_funct3 == 3'b101;

  logic [`REG_SIZE] w_load_data;
  always_comb begin
    w_load_data = 32'd0;
    case (1'b1)
      w_is_lw: w_load_data = load_data_from_dmem;
      w_is_lh: begin
        case (writeback_state.mem_addr_lsb[1])
          1'b0: w_load_data = {{16{load_data_from_dmem[15]}}, load_data_from_dmem[15:0]};
          1'b1: w_load_data = {{16{load_data_from_dmem[31]}}, load_data_from_dmem[31:16]};
        endcase
      end
      w_is_lhu: begin
        case (writeback_state.mem_addr_lsb[1])
          1'b0: w_load_data = {16'b0, load_data_from_dmem[15:0]};
          1'b1: w_load_data = {16'b0, load_data_from_dmem[31:16]};
        endcase
      end
      w_is_lb: begin
        case (writeback_state.mem_addr_lsb)
          2'b00: w_load_data = {{24{load_data_from_dmem[7]}}, load_data_from_dmem[7:0]};
          2'b01: w_load_data = {{24{load_data_from_dmem[15]}}, load_data_from_dmem[15:8]};
          2'b10: w_load_data = {{24{load_data_from_dmem[23]}}, load_data_from_dmem[23:16]};
          2'b11: w_load_data = {{24{load_data_from_dmem[31]}}, load_data_from_dmem[31:24]};
        endcase
      end
      w_is_lbu: begin
        case (writeback_state.mem_addr_lsb)
          2'b00: w_load_data = {24'b0, load_data_from_dmem[7:0]};
          2'b01: w_load_data = {24'b0, load_data_from_dmem[15:8]};
          2'b10: w_load_data = {24'b0, load_data_from_dmem[23:16]};
          2'b11: w_load_data = {24'b0, load_data_from_dmem[31:24]};
        endcase
      end
      default: w_load_data = 32'd0;
    endcase
  end

  assign w_rd = writeback_state.rd;
  assign w_rd_data = writeback_state.is_load ? w_load_data : writeback_state.rd_data;
  assign w_rd_we = writeback_state.rd_we;

  assign halt = writeback_state.halt;

  assign trace_completed_pc = writeback_state.pc;
  assign trace_completed_insn = writeback_state.insn;
  assign trace_completed_cycle_status = writeback_state.cycle_status;
  assign trace_writeback_pc = writeback_state.pc;
  assign trace_writeback_insn = writeback_state.insn;
  assign trace_writeback_cycle_status = writeback_state.cycle_status;

endmodule

/* -----------------------------------------------------------------------------
 * VERIFICATION HARNESS ONLY -- not part of the AgriASIC chip build.
 *
 * Unified synchronous memory matching the timing contract of agriasic_imem /
 * agriasic_dmem, so the class regression (riscv-tests, dhrystone) can be run
 * against the modified core. The real chip uses separate ROM and RAM instances
 * via agriasic_rv32i_mmio; this model exists only so the verified traces still
 * have something to drive.
 *
 * Contract: address captured on posedge under ce, data valid the NEXT cycle,
 * output register holds while ce is low.
 * ---------------------------------------------------------------------------*/
module MemorySyncUnified #(
    parameter int NUM_WORDS = 8192
) (
    input wire rst,
    input wire clk,

    // read-only instruction port
    input  wire  [`REG_SIZE]  pc_to_imem,
    input  wire               imem_ce,
    output logic [`INSN_SIZE] insn_from_imem,

    // read/write data port
    input  wire  [`REG_SIZE] addr_to_dmem,
    input  wire              dmem_read_en,
    output logic [`REG_SIZE] load_data_from_dmem,
    input  wire  [`REG_SIZE] store_data_to_dmem,
    input  wire  [3:0]       store_we_to_dmem
);

  logic [`REG_SIZE] mem_array[NUM_WORDS];

  initial begin
    $readmemh("mem_initial_contents.hex", mem_array);
  end

  localparam int AddrMsb = $clog2(NUM_WORDS) + 1;
  localparam int AddrLsb = 2;

  // Instruction port: synchronous read, output holds when ce is low.
  always_ff @(posedge clk) begin
    if (rst) begin
      insn_from_imem <= 32'd0;
    end else if (imem_ce) begin
      insn_from_imem <= mem_array[pc_to_imem[AddrMsb:AddrLsb]];
    end
  end

  // Data port: synchronous single-port read or write.
  wire dmem_ce = dmem_read_en || (|store_we_to_dmem);

  always_ff @(posedge clk) begin
    if (rst) begin
      load_data_from_dmem <= 32'd0;
    end else if (dmem_ce) begin
      if (|store_we_to_dmem) begin
        if (store_we_to_dmem[0]) mem_array[addr_to_dmem[AddrMsb:AddrLsb]][7:0]   <= store_data_to_dmem[7:0];
        if (store_we_to_dmem[1]) mem_array[addr_to_dmem[AddrMsb:AddrLsb]][15:8]  <= store_data_to_dmem[15:8];
        if (store_we_to_dmem[2]) mem_array[addr_to_dmem[AddrMsb:AddrLsb]][23:16] <= store_data_to_dmem[23:16];
        if (store_we_to_dmem[3]) mem_array[addr_to_dmem[AddrMsb:AddrLsb]][31:24] <= store_data_to_dmem[31:24];
      end else begin
        load_data_from_dmem <= mem_array[addr_to_dmem[AddrMsb:AddrLsb]];
      end
    end
  end

endmodule

/* Verification top level. Single clock, as before. */
module Processor (
    input  wire  clk,
    input  wire  rst,
    output logic halt,
    output wire [`REG_SIZE] trace_completed_pc,
    output wire [`INSN_SIZE] trace_completed_insn,
    output cycle_status_e trace_completed_cycle_status
);

  wire [`INSN_SIZE] insn_from_imem;
  wire [`REG_SIZE] pc_to_imem, mem_data_addr, mem_data_loaded_value, mem_data_to_write;
  wire [3:0] mem_data_we;
  wire imem_ce, mem_read_en;
  wire [`REG_SIZE] trace_writeback_pc_unused;
  wire [`INSN_SIZE] trace_writeback_insn_unused;
  cycle_status_e trace_writeback_cycle_status_unused;

  // Set by cocotb to the name of the running test, for waveform readability.
  wire [(8*32)-1:0] test_case;

  MemorySyncUnified #(
      .NUM_WORDS(8192)
  ) memory (
      .rst                (rst),
      .clk                (clk),
      .pc_to_imem         (pc_to_imem),
      .imem_ce            (imem_ce),
      .insn_from_imem     (insn_from_imem),
      .addr_to_dmem       (mem_data_addr),
      .dmem_read_en       (mem_read_en),
      .load_data_from_dmem(mem_data_loaded_value),
      .store_data_to_dmem (mem_data_to_write),
      .store_we_to_dmem   (mem_data_we)
  );

  DatapathPipelined datapath (
      .clk(clk),
      .rst(rst),
      .pc_to_imem(pc_to_imem),
      .insn_from_imem(insn_from_imem),
      .addr_to_dmem(mem_data_addr),
      .store_data_to_dmem(mem_data_to_write),
      .store_we_to_dmem(mem_data_we),
      .imem_ce_o(imem_ce),
      .mem_read_en_o(mem_read_en),
      .load_data_from_dmem(mem_data_loaded_value),
      .halt(halt),
      .trace_completed_pc(trace_completed_pc),
      .trace_completed_insn(trace_completed_insn),
      .trace_completed_cycle_status(trace_completed_cycle_status),
      .trace_writeback_pc(trace_writeback_pc_unused),
      .trace_writeback_insn(trace_writeback_insn_unused),
      .trace_writeback_cycle_status(trace_writeback_cycle_status_unused)
  );

endmodule
