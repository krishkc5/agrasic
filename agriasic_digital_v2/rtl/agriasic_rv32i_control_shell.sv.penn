// -----------------------------------------------------------------------------
// Module: agriasic_rv32i_control_shell
// Purpose:
//   RV32I control shell for the AgriASIC measurement node. Wraps the RV32IM
//   pipelined core, its instruction ROM, and the memory-mapped peripheral
//   bridge that drives the measurement engine.
//
// Partition (policy vs. mechanism):
//   - Software here decides WHEN to measure, with WHICH configuration, and what
//     to do with results (calibration, averaging, compensation).
//   - The measurement FSM remains the real-time engine. Nothing cycle-accurate
//     lives in firmware: excitation polarity, settle qualification, conversion
//     trigger and accumulation are all hardware, so the sample instant has no
//     jitter and the +/- chop stays time-symmetric.
//
// Port list is IDENTICAL to the previous microsequencer implementation, so
// agriasic_digital_rv32i_top requires no changes. The previous implementation
// is preserved alongside as agriasic_rv32i_control_shell.sv.orig.
//
// Run control:
//   The core is held in reset while start_i is low and runs from PC 0 when
//   start_i is asserted, matching the previous shell's IDLE -> run -> IDLE
//   behavior. Holding the core in reset between measurements is also the
//   power-saving state for a solar/battery node.
//
// Core clock enable (Rev 4.3 Phase 2.2):
//   The core has nothing to do while a measurement is in flight -- the
//   measurement FSM owns that window entirely. From the cycle after firmware
//   issues start_pulse_o (so the triggering MMIO store itself completes
//   normally) until measurement_done_i asserts, core_clk_en is held low and
//   every register in DatapathPipelined (and the register file) holds. This
//   is automatic and needs no firmware cooperation: firmware does not poll
//   for completion, it simply resumes the cycle after done_i, by which point
//   result_q below already holds the fresh result.
//   "Clock enable, not a gated clock" (MAS section 8.1): clk itself is never
//   ANDed with anything here. core_clk_en is an ordinary synchronous enable
//   input threaded into the core's own always_ff blocks.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module agriasic_rv32i_control_shell #(
  parameter int unsigned ADC_WIDTH = 8
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 start_i,
  input  logic                 measurement_done_i,
  input  logic signed [15:0]   measurement_result_i_i,  // I channel (Rev 4.3 Phase 5)
  input  logic signed [15:0]   measurement_result_q_i,  // Q channel (Rev 4.3 Phase 5)

  output logic                 busy_o,
  output logic                 done_o,
  output logic                 start_pulse_o,
  output logic                 clear_errors_o,

  output logic [3:0]           cfg_pair_log2_o,
  output logic [7:0]           cfg_settle_cycles_o,
  output logic [13:0]          cfg_exc_divider_o,  // Rev 4.3 Phase 4.2: widened 8->14 bits, see GAP-1
  output logic [7:0]           cfg_conv_cycles_o,
  output logic signed [15:0]   result_i_o,  // Rev 4.3 Phase 5: I channel
  output logic signed [15:0]   result_q_o   // Rev 4.3 Phase 5: Q channel
);

  // ADC_WIDTH is retained for interface compatibility; the control core does
  // not touch ADC samples directly, only the accumulated result.
  localparam int unsigned IMEM_WORDS = 1024;  // 4 KB program ROM
  localparam int unsigned DMEM_WORDS = 512;   // 2 KB scratch RAM

  // --------------------------------------------------------------------------
  // Core reset control
  //
  // The core uses active-high synchronous reset; the chip uses active-low
  // async. Registering the conversion also gives the synchronous release the
  // core's register file needs (its reset loop is synchronous, so the clock
  // must be running while reset is asserted).
  // --------------------------------------------------------------------------
  logic core_rst;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      core_rst <= 1'b1;
    end else begin
      core_rst <= !start_i;
    end
  end

  // --------------------------------------------------------------------------
  // Core <-> memory wiring
  // --------------------------------------------------------------------------
  logic [31:0] pc_to_imem;
  logic [31:0] insn_from_imem;
  logic        imem_ce;

  logic [31:0] addr_to_dmem;
  logic [31:0] store_data_to_dmem;
  logic [3:0]  store_we_to_dmem;
  logic [31:0] load_data_from_dmem;
  logic        mem_read_en;

  logic        core_halt;

  // --------------------------------------------------------------------------
  // Core clock enable -- see the header note.
  //
  // meas_inflight_q is set the cycle after start_pulse_o (letting the
  // triggering store complete at full speed) and cleared the cycle
  // measurement_done_i asserts, so the core resumes exactly when a fresh
  // result is ready.
  // --------------------------------------------------------------------------
  logic meas_inflight_q;
  logic core_clk_en;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      meas_inflight_q <= 1'b0;
    end else if (start_pulse_o) begin
      meas_inflight_q <= 1'b1;
    end else if (measurement_done_i) begin
      meas_inflight_q <= 1'b0;
    end
  end

  assign core_clk_en = !meas_inflight_q;

  DatapathPipelined u_core (
    .clk                          (clk),
    .rst                          (core_rst),
    .clk_en_i                     (core_clk_en),
    .pc_to_imem                   (pc_to_imem),
    .insn_from_imem               (insn_from_imem),
    .addr_to_dmem                 (addr_to_dmem),
    .load_data_from_dmem          (load_data_from_dmem),
    .store_data_to_dmem           (store_data_to_dmem),
    .store_we_to_dmem             (store_we_to_dmem),
    .imem_ce_o                    (imem_ce),
    .mem_read_en_o                (mem_read_en),
    .halt                         (core_halt),
    // Trace ports are verification-only and intentionally unconnected here.
    .trace_completed_pc           (),
    .trace_completed_insn         (),
    .trace_completed_cycle_status (),
    .trace_writeback_pc           (),
    .trace_writeback_insn         (),
    .trace_writeback_cycle_status ()
  );

  // Program ROM. Its output register serves as the core's Fetch/Decode
  // pipeline register, which is why imem_ce must be driven by the core.
  agriasic_imem #(
    .NUM_WORDS(IMEM_WORDS),
    .INIT_FILE("agriasic_fw.hex")
  ) u_imem (
    .clk    (clk),
    .rst_n  (rst_n),
    .ce_i   (imem_ce),
    .addr_i (pc_to_imem),
    .dout_o (insn_from_imem)
  );

  // --------------------------------------------------------------------------
  // Measurement-in-flight flag
  //
  // The shell has no busy input from the measurement engine, so busy is tracked
  // here: set when firmware issues a start, cleared when the engine reports
  // done. This is what firmware polls via STATUS bit 0.
  // --------------------------------------------------------------------------
  // Data-side bus: scratch RAM plus the peripheral window.
  agriasic_rv32i_mmio #(
    .RAM_WORDS(DMEM_WORDS)
  ) u_mmio (
    .clk                 (clk),
    .rst_n               (rst_n),
    .addr_i              (addr_to_dmem),
    .wdata_i             (store_data_to_dmem),
    .we_i                (store_we_to_dmem),
    .read_en_i           (mem_read_en),
    .rdata_o             (load_data_from_dmem),
    .start_pulse_o       (start_pulse_o),
    .clear_errors_o      (clear_errors_o),
    .cfg_pair_log2_o     (cfg_pair_log2_o),
    .cfg_settle_cycles_o (cfg_settle_cycles_o),
    .cfg_exc_divider_o   (cfg_exc_divider_o),
    .cfg_conv_cycles_o   (cfg_conv_cycles_o),
    .done_i              (measurement_done_i),
    .result_i_i          (measurement_result_i_i),
    .result_q_i          (measurement_result_q_i)
  );

  // --------------------------------------------------------------------------
  // Shell status
  //
  // Latch both measurement results so result_i_o/result_q_o stay stable after
  // done, matching the previous (Phase 4 and earlier) shell's single-channel
  // behavior.
  // --------------------------------------------------------------------------
  logic signed [15:0] result_i_q;
  logic signed [15:0] result_q_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result_i_q <= 16'd0;
      result_q_q <= 16'd0;
    end else if (!start_i) begin
      result_i_q <= 16'd0;
      result_q_q <= 16'd0;
    end else if (measurement_done_i) begin
      result_i_q <= measurement_result_i_i;
      result_q_q <= measurement_result_q_i;
    end
  end

  assign result_i_o = result_i_q;
  assign result_q_o = result_q_q;
  assign done_o     = core_halt;                 // firmware reached ecall
  assign busy_o     = !core_rst && !core_halt;   // program running

endmodule
