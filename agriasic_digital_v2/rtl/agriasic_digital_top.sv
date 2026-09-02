// -----------------------------------------------------------------------------
// Module: agriasic_digital_top
// Purpose:
//   Top-level digital wrapper for the AgriASIC measurement path.
//
// Functionality:
//   1) Instantiates excitation control, SAR control, and measurement FSM blocks.
//   2) Routes phase-settle and sample request handshakes between control blocks.
//   3) Aggregates completion and accumulated result to top outputs.
//
// Notes:
//   - SPI/regfile integration is intentionally left decoupled so this module can
//     be stimulated directly from verification environments.
// -----------------------------------------------------------------------------
module agriasic_digital_top #(
  parameter int unsigned ADC_WIDTH = 8
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   start,
  input  logic [3:0]             cfg_pair_log2_i,
  input  logic [7:0]             cfg_settle_cycles_i,
  input  logic [7:0]             cfg_exc_divider_i,
  input  logic [7:0]             cfg_conv_cycles_i,
  input  logic [ADC_WIDTH-1:0]   adc_code_i,
  output logic                   conv_start_o,
  output logic                   exc_pol_o,
  output logic                   busy_o,
  output logic                   done_o,
  output logic [15:0]            result_o
);

  logic [ADC_WIDTH-1:0] d_plus;
  logic [ADC_WIDTH-1:0] d_minus;
  logic                 exc_set_phase;
  logic                 exc_phase;
  logic                 exc_settled;
  logic                 exc_tick;
  logic                 sample_req;
  logic                 sample_phase;
  logic                 sample_done;
  logic                 exc_enable;
  logic                 sar_busy;

  // Excitation controller handles polarity and settle timing.
  excitation_ctrl u_excitation_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
    .enable_i        (exc_enable),
    .set_phase_i     (exc_set_phase),
    .phase_value_i   (exc_phase),
    .settle_cycles_i (cfg_settle_cycles_i),
    .divider_i       (cfg_exc_divider_i),
    .polarity_o      (exc_pol_o),
    .settled_o       (exc_settled),
    .tick_o          (exc_tick)
  );

  // SAR control/collection with programmable conversion latency.
  sar_controller #(
    .ADC_WIDTH   (ADC_WIDTH)
  ) u_sar_controller (
    .clk            (clk),
    .rst_n          (rst_n),
    .sample_req_i   (sample_req),
    .sample_phase_i (sample_phase),
    .conv_cycles_i  (cfg_conv_cycles_i),
    .adc_code_i     (adc_code_i),
    .conv_start_o   (conv_start_o),
    .sample_done_o  (sample_done),
    .busy_o         (sar_busy),
    .d_plus_o       (d_plus),
    .d_minus_o      (d_minus)
  );

  // Measurement FSM coordinates settle/sample/accumulate loop.
  measurement_fsm #(
    .ADC_WIDTH   (ADC_WIDTH)
  ) u_measurement_fsm (
    .clk             (clk),
    .rst_n           (rst_n),
    .start_i         (start),
    .pair_log2_i     (cfg_pair_log2_i),
    .settled_i       (exc_settled),
    .sar_done_i      (sample_done),
    .d_plus_i        (d_plus),
    .d_minus_i       (d_minus),
    .exc_enable_o    (exc_enable),
    .exc_set_phase_o (exc_set_phase),
    .exc_phase_o     (exc_phase),
    .sample_req_o    (sample_req),
    .sample_phase_o  (sample_phase),
    .busy_o          (busy_o),
    .done_o          (done_o),
    .result_o        (result_o)
  );

endmodule
