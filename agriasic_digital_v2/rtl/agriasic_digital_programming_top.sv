// -----------------------------------------------------------------------------
// Module: agriasic_digital_programming_top
// Purpose:
//   Programming-oriented wrapper for the optional RV32I controller
//   architecture. This wrapper keeps the measurement FSM as the real-time
//   engine and exposes a compact programming surface for firmware-driven setup.
//
// Notes:
//   - This is a control/programming layer, not the timing-critical measurement
//     engine itself.
//   - The wrapper keeps the same measurement core used by the SPI top-level.
//   - A future RV32I core with ROM can drive the program/write inputs directly.
//   - SUPERSEDED by agriasic_rv32i_control_shell / agriasic_digital_rv32i_top,
//     which is the built RV32I integration. Kept and maintained (it tracks the
//     measurement core's interface, including the Rev 5 tetrapolar change) so
//     it still elaborates, but nothing in the regression builds it.
// -----------------------------------------------------------------------------
module agriasic_digital_programming_top #(
  parameter int unsigned ADC_WIDTH = 8
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // Compact programming interface intended for an RV32I firmware controller.
  input  logic                 prog_cfg_we_i,
  input  logic [1:0]           prog_cfg_addr_i,
  input  logic [7:0]           prog_cfg_data_i,
  input  logic                 prog_start_i,

  output logic                 afe_conv_start_o,
  output logic [ADC_WIDTH-1:0] afe_sine_code_o,     // Rev 5: sine DAC code -> E1 drive buffer
  output logic [1:0]           afe_mux_sel_o,       // Rev 5: 0 = dV (PGA), 1 = I (TIA)
  output logic                 afe_adc_enable_o,
  output logic                 afe_sample_o,
  output logic [ADC_WIDTH-1:0] afe_adc_dac_o,
  input  logic                 afe_adc_comp_i,
  output logic                 dbg_busy_o,
  output logic                 dbg_done_o,
  output logic signed [15:0]   dbg_result_dv_i_o,   // Rev 5: dV in-phase
  output logic signed [15:0]   dbg_result_dv_q_o,   // Rev 5: dV quadrature
  output logic signed [15:0]   dbg_result_cur_i_o,  // Rev 5: current in-phase
  output logic signed [15:0]   dbg_result_cur_q_o,  // Rev 4.3 Phase 5: Q channel

  // Expose the active programming state for debug and bring-up.
  output logic [3:0]           dbg_cfg_pair_log2_o,
  output logic [7:0]           dbg_cfg_settle_cycles_o,
  output logic [13:0]          dbg_cfg_exc_divider_o,  // Rev 4.3 Phase 4.2: widened 8->14 bits, see GAP-1
  output logic [7:0]           dbg_cfg_conv_cycles_o
);

  // Rev 4.3 Phase 2.1: rst_n is the raw, possibly-asynchronous chip pin.
  // Everything internal runs off rst_n_sync, released synchronously to clk.
  logic rst_n_sync;
  rst_sync u_rst_sync (
    .clk     (clk),
    .rst_n_i (rst_n),
    .rst_n_o (rst_n_sync)
  );

  logic       start_pulse_q;
  logic       prog_start_q;
  logic [3:0]  cfg_pair_log2_q;
  logic [7:0]  cfg_settle_q;
  // Rev 4.3 Phase 6: like SPI's REG_FREQ_SEL, this is a 2-bit SELECTOR
  // (0/1/2), not raw N -- this interface's prog_cfg_data_i is also just 8
  // bits, the same byte-width limit that motivated the same choice on SPI
  // (see agriasic_digital_spi_top.sv's header). Translated to N below.
  logic [1:0]  cfg_freq_sel_q;
  logic [7:0]  cfg_conv_q;

  localparam logic [1:0] CFG_PAIR_LOG2 = 2'd0;
  localparam logic [1:0] CFG_SETTLE    = 2'd1;
  localparam logic [1:0] CFG_FREQ_SEL  = 2'd2;
  localparam logic [1:0] CFG_CONV      = 2'd3;

  // Same three exact presets as SPI's REG_FREQ_SEL (f_clk=160 MHz):
  // N=1 -> 10 MHz, N=100 -> 100 kHz, N=10000 -> 1 kHz.
  logic [13:0] cfg_divider_w;
  always_comb begin
    unique case (cfg_freq_sel_q)
      2'd0:    cfg_divider_w = 14'd1;
      2'd1:    cfg_divider_w = 14'd100;
      2'd2:    cfg_divider_w = 14'd10000;
      default: cfg_divider_w = 14'd1;
    endcase
  end

  assign dbg_cfg_pair_log2_o     = cfg_pair_log2_q;
  assign dbg_cfg_settle_cycles_o = cfg_settle_q;
  assign dbg_cfg_exc_divider_o   = cfg_divider_w;
  assign dbg_cfg_conv_cycles_o   = cfg_conv_q;

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) u_core (
    .clk                (clk),
    .rst_n              (rst_n_sync),
    .start              (start_pulse_q),
    .cfg_pair_log2_i    (cfg_pair_log2_q),
    .cfg_settle_cycles_i(cfg_settle_q),
    .cfg_exc_divider_i  (cfg_divider_w),
    .cfg_conv_cycles_i  (cfg_conv_q),
    // Rev 5: not exposed on this legacy programming surface -- fixed defaults.
    .cfg_mux_settle_i   (8'd2),
    .cfg_amplitude_i    (2'd0),
    .afe_conv_start_o       (afe_conv_start_o),
    .afe_sine_code_o        (afe_sine_code_o),
    .afe_mux_sel_o          (afe_mux_sel_o),
    .afe_adc_enable_o       (afe_adc_enable_o),
    .afe_sample_o       (afe_sample_o),
    .afe_adc_dac_o          (afe_adc_dac_o),
    .afe_adc_comp_i         (afe_adc_comp_i),
    .busy_o             (dbg_busy_o),
    .done_o             (dbg_done_o),
    .result_dv_i_o      (dbg_result_dv_i_o),
    .result_dv_q_o      (dbg_result_dv_q_o),
    .result_cur_i_o     (dbg_result_cur_i_o),
    .result_cur_q_o     (dbg_result_cur_q_o)
  );

  always_ff @(posedge clk or negedge rst_n_sync) begin
    if (!rst_n_sync) begin
      start_pulse_q   <= 1'b0;
      prog_start_q    <= 1'b0;
      cfg_pair_log2_q <= 4'd2;
      cfg_settle_q    <= 8'd2;
      cfg_freq_sel_q  <= 2'd0;
      cfg_conv_q      <= 8'd1;
    end else begin
      start_pulse_q <= prog_start_i & ~prog_start_q;
      prog_start_q  <= prog_start_i;

      if (prog_cfg_we_i) begin
        unique case (prog_cfg_addr_i)
          CFG_PAIR_LOG2: cfg_pair_log2_q <= prog_cfg_data_i[3:0];
          CFG_SETTLE:    cfg_settle_q    <= prog_cfg_data_i;
          CFG_FREQ_SEL:  cfg_freq_sel_q  <= prog_cfg_data_i[1:0];
          CFG_CONV:      cfg_conv_q      <= prog_cfg_data_i;
          default: begin
          end
        endcase
      end
    end
  end

endmodule
