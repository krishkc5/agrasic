// -----------------------------------------------------------------------------
// Module: agriasic_digital_top
// Purpose:
//   Top-level digital wrapper for the AgriASIC measurement path.
//
// Functionality:
//   1) Instantiates excitation control, SAR control, and measurement FSM blocks.
//   2) Routes the free-running phase reference and sample request handshakes
//      between control blocks (Rev 4.3 Phase 4: excitation_ctrl runs on its
//      own; measurement_fsm watches its phase counter rather than commanding
//      flips -- see excitation_ctrl.sv and measurement_fsm.sv).
//   3) Aggregates completion and accumulated result to top outputs.
//
// Analog boundary (Rev 4.3):
//   Only these signals cross into the analog front end: exc_drive_p_o and
//   exc_drive_n_o (break-before-make excitation drive, see excitation_ctrl),
//   and the SAR bit-trial interface adc_enable_o / adc_sample_o / adc_dac_o /
//   adc_comp_i (see sar_controller). adc_comp_i is a timed, unsynchronized
//   path -- do not add a synchronizer on it.
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
  input  logic [13:0]            cfg_exc_divider_i,  // Rev 4.3 Phase 4.2: widened 8->14 bits, see GAP-1
  input  logic [7:0]             cfg_conv_cycles_i,
  output logic                   conv_start_o,
  output logic                   exc_drive_p_o,
  output logic                   exc_drive_n_o,
  output logic                   adc_enable_o,
  output logic                   adc_sample_o,
  output logic [ADC_WIDTH-1:0]   adc_dac_o,
  input  logic                   adc_comp_i,
  output logic                   busy_o,
  output logic                   done_o,
  output logic [15:0]            result_o
);

  logic [ADC_WIDTH-1:0] d_plus;
  logic [ADC_WIDTH-1:0] d_minus;
  logic [3:0]           exc_phase_index;
  logic                 exc_period_tick;
  logic                 sample_req;
  logic                 sample_phase;
  logic                 sample_done;
  logic                 exc_enable;
  logic                 sar_busy;

  // Excitation controller: free-running divider + phase counter (Rev 4.3
  // Phase 4). No more commanded flips -- measurement_fsm watches
  // exc_phase_index instead.
  excitation_ctrl u_excitation_ctrl (
    .clk            (clk),
    .rst_n          (rst_n),
    .enable_i       (exc_enable),
    .divider_i      (cfg_exc_divider_i),
    .drive_p_o      (exc_drive_p_o),
    .drive_n_o      (exc_drive_n_o),
    .phase_index_o  (exc_phase_index),
    .period_tick_o  (exc_period_tick)
  );

  // SAR control: runs the bit-trial search against the analog comparator.
  sar_controller #(
    .ADC_WIDTH   (ADC_WIDTH)
  ) u_sar_controller (
    .clk            (clk),
    .rst_n          (rst_n),
    .sample_req_i   (sample_req),
    .sample_phase_i (sample_phase),
    .conv_cycles_i  (cfg_conv_cycles_i),
    .conv_start_o   (conv_start_o),
    .sample_done_o  (sample_done),
    .busy_o         (sar_busy),
    .d_plus_o       (d_plus),
    .d_minus_o      (d_minus),
    .adc_enable_o   (adc_enable_o),
    .adc_sample_o   (adc_sample_o),
    .adc_dac_o      (adc_dac_o),
    .adc_comp_i     (adc_comp_i)
  );

  // Measurement FSM: watches the free-running phase counter and strobes
  // samples at the assigned phase instants (Rev 4.3 Phase 4).
  measurement_fsm #(
    .ADC_WIDTH   (ADC_WIDTH)
  ) u_measurement_fsm (
    .clk             (clk),
    .rst_n           (rst_n),
    .start_i         (start),
    .pair_log2_i     (cfg_pair_log2_i),
    .settle_cycles_i (cfg_settle_cycles_i),
    .phase_index_i   (exc_phase_index),
    .period_tick_i   (exc_period_tick),
    .sar_done_i      (sample_done),
    .d_plus_i        (d_plus),
    .d_minus_i       (d_minus),
    .exc_enable_o    (exc_enable),
    .sample_req_o    (sample_req),
    .sample_phase_o  (sample_phase),
    .busy_o          (busy_o),
    .done_o          (done_o),
    .result_o        (result_o)
  );

endmodule
