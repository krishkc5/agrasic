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
//   3) Aggregates completion and all four accumulated results (dV and current,
//      each in-phase and quadrature) to top outputs.
//
// Analog boundary (Rev 5, tetrapolar front end):
//   Only these signals cross into the analog front end:
//     afe_sine_code_o   8-bit cosine code to the sine DAC driving E1 (offset
//                   binary, mid-code = VCM; see excitation_ctrl)
//     afe_mux_sel_o     analog mux: 0 = dV from the differential PGA on E2/E3,
//                   1 = return current from the TIA on E4
//     afe_sample_o  track-and-hold strobe -- fires ONCE per phase point and
//                   freezes BOTH channels' sample-and-holds simultaneously,
//                   which is what preserves the voltage/current phase
//                   relationship across the two sequential conversions
//     afe_adc_enable_o / afe_adc_dac_o / afe_adc_comp_i / afe_conv_start_o
//                   the SAR bit-trial interface (see sar_controller)
//   afe_adc_comp_i is a timed, unsynchronized path -- do not add a synchronizer.
//   Impedance Z(f) = dV(f) / I(f) is computed host-side from the four
//   accumulators, never on die.
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
  input  logic [7:0]             cfg_mux_settle_i,   // Rev 5: analog mux + S/H settling
  input  logic [1:0]             cfg_amplitude_i,    // Rev 5: sine excursion 0=full,1=1/2,2=1/4,3=1/8
  output logic                   afe_conv_start_o,
  output logic [ADC_WIDTH-1:0]   afe_sine_code_o,        // Rev 5: sine DAC code for the E1 drive buffer
  output logic                   afe_adc_enable_o,
  output logic                   afe_sample_o,       // strobes BOTH sample-and-holds
  output logic [1:0]             afe_mux_sel_o,          // Rev 5: 0 = dV (PGA), 1 = I (TIA)
  output logic [ADC_WIDTH-1:0]   afe_adc_dac_o,
  input  logic                   afe_adc_comp_i,
  output logic                   busy_o,
  output logic                   done_o,
  // Rev 5: two channels. Z(f) = dV(f) / I(f) is computed host-side.
  output logic signed [15:0]     result_dv_i_o,      // sum( dV(0)  - dV(180) )
  output logic signed [15:0]     result_dv_q_o,      // sum( dV(90) - dV(270) )
  output logic signed [15:0]     result_cur_i_o,     // sum(  I(0)  -  I(180) )
  output logic signed [15:0]     result_cur_q_o      // sum(  I(90) -  I(270) )
);

  logic [ADC_WIDTH-1:0] sar_code;
  logic [3:0]           exc_phase_index;
  logic                 exc_period_tick;
  logic                 sample_req;
  logic                 take_sample;
  logic [1:0]           channel;
  logic                 sample_done;
  logic                 exc_enable;

  // Excitation controller: free-running divider + phase counter (Rev 4.3
  // Phase 4). No more commanded flips -- measurement_fsm watches
  // exc_phase_index instead.
  excitation_ctrl u_excitation_ctrl (
    .clk            (clk),
    .rst_n          (rst_n),
    .enable_i       (exc_enable),
    .divider_i      (cfg_exc_divider_i),
    .amplitude_i    (cfg_amplitude_i),
    .sine_code_o    (afe_sine_code_o),
    .phase_index_o  (exc_phase_index),
    .period_tick_o  (exc_period_tick)
  );

  // SAR control: runs the bit-trial search against the analog comparator.
  sar_controller #(
    .ADC_WIDTH   (ADC_WIDTH)
  ) u_sar_controller (
    .clk            (clk),
    .rst_n          (rst_n),
    .sample_req_i        (sample_req),
    .take_sample_i       (take_sample),
    .channel_i           (channel),
    .conv_cycles_i       (cfg_conv_cycles_i),
    .mux_settle_cycles_i (cfg_mux_settle_i),
    .conv_start_o        (afe_conv_start_o),
    .sample_done_o       (sample_done),
    .busy_o              (),  // not consumed: measurement_fsm tracks its own busy state via sample_done_i
    .code_o              (sar_code),
    .mux_sel_o           (afe_mux_sel_o),
    .adc_enable_o        (afe_adc_enable_o),
    .adc_sample_o        (afe_sample_o),
    .adc_dac_o           (afe_adc_dac_o),
    .adc_comp_i          (afe_adc_comp_i)
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
    .code_i          (sar_code),
    .exc_enable_o    (exc_enable),
    .sample_req_o    (sample_req),
    .take_sample_o   (take_sample),
    .channel_o       (channel),
    .busy_o          (busy_o),
    .done_o          (done_o),
    .result_dv_i_o   (result_dv_i_o),
    .result_dv_q_o   (result_dv_q_o),
    .result_cur_i_o  (result_cur_i_o),
    .result_cur_q_o  (result_cur_q_o)
  );

endmodule
