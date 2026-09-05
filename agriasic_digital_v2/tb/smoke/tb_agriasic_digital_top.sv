`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_agriasic_digital_top
// Purpose:
//   Smoke test for top-level digital integration -- self-checking.
//
// What this test checks:
//   1) One full 4-pair measurement run produces the exact expected raw
//      accumulated result.
//   2) Every D+/D- sample lands on the EXACT phase_index the design doc
//      specifies (0 and 8), not just "somewhere in the right half" -- the
//      comparator model alone can't distinguish those, since it reads
//      exc_drive_p_o, which is true across the whole phase 0-6 range.
// -----------------------------------------------------------------------------
module tb_agriasic_digital_top;
  localparam int unsigned ADC_WIDTH = 8;
  localparam int unsigned EXPECTED_RESULT = 16'd480;

  logic clk;
  logic rst_n;
  logic start;
  logic [3:0]  cfg_pair_log2_i;
  logic [7:0]  cfg_settle_cycles_i;
  logic [13:0] cfg_exc_divider_i;
  logic [7:0]  cfg_conv_cycles_i;
  logic conv_start_o;
  logic exc_drive_p_o;
  logic exc_drive_n_o;
  logic adc_enable_o;
  logic adc_sample_o;
  logic [ADC_WIDTH-1:0] adc_dac_o;
  logic adc_comp_i;
  logic busy_o;
  logic done_o;
  logic [15:0] result_o;

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .cfg_pair_log2_i(cfg_pair_log2_i),
    .cfg_settle_cycles_i(cfg_settle_cycles_i),
    .cfg_exc_divider_i(cfg_exc_divider_i),
    .cfg_conv_cycles_i(cfg_conv_cycles_i),
    .conv_start_o(conv_start_o),
    .exc_drive_p_o(exc_drive_p_o),
    .exc_drive_n_o(exc_drive_n_o),
    .adc_enable_o(adc_enable_o),
    .adc_sample_o(adc_sample_o),
    .adc_dac_o(adc_dac_o),
    .adc_comp_i(adc_comp_i),
    .busy_o(busy_o),
    .done_o(done_o),
    .result_o(result_o)
  );

  // 100 MHz equivalent simulation clock.
  always #5 clk = ~clk;

  // Behavioral comparator model for the Rev 4.3 SAR bit-trial interface.
  // Positive phase target is higher than negative phase target, yielding
  // pair_delta = 180 - 60 = 120 (raw, unscaled). With 4 pairs, result is 480.
  // See sar_controller's header for the adc_comp_i convention this implements.
  //
  // Rev 4.3 Phase 4: excitation is now free-running, so exc_drive_p_o can
  // change WHILE a single bit-trial conversion is still in progress (a
  // conversion takes ~24+ clk cycles; one phase state can last as little as
  // N=1 cycle). Real track-and-hold freezes the analog input at the
  // adc_sample_o pulse and holds it for the whole conversion; this model
  // must do the same -- latch the target on adc_sample_o, not re-derive it
  // live from the (possibly already-moved-on) drive signal.
  logic [ADC_WIDTH-1:0] adc_target_held_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      adc_target_held_q <= exc_drive_p_o ? 8'd180 : 8'd60;
    end
  end
  assign adc_comp_i = (adc_target_held_q >= adc_dac_o);

  // --------------------------------------------------------------------------
  // Precise phase-match check (Rev 4.3 Phase 4).
  //
  // The comparator model above is keyed on exc_drive_p_o, which reads true
  // across the WHOLE positive half (phase 0-6) -- so a bug that sampled at,
  // say, phase 3 instead of the documented phase 0 would still produce a
  // numerically correct result and pass silently. This checks the actual
  // phase_index at the moment each sample was requested, using
  // measurement_fsm's own named states/localparams hierarchically so it
  // can't drift out of sync with a future state reordering.
  // --------------------------------------------------------------------------
  // measurement_fsm's state_t enum, in declaration order (default SV
  // encoding: 0,1,2,...). Hierarchical access to the enum LITERALS
  // themselves crashes this Verilator version (internal fault), so this
  // compares the raw state_q value against its numeric position instead --
  // fragile only if that declaration order changes, which is exactly why
  // this comment exists.
  //   0=S_IDLE 1=S_SETTLE 2=S_WAIT_P 3=S_SAMPLE_P 4=S_WAIT_N 5=S_SAMPLE_N
  //   6=S_ACCUM 7=S_LOOP 8=S_DONE
  localparam logic [3:0] ST_WAIT_P   = 4'd2;
  localparam logic [3:0] ST_SAMPLE_P = 4'd3;
  localparam logic [3:0] ST_WAIT_N   = 4'd4;
  localparam logic [3:0] ST_SAMPLE_N = 4'd5;

  logic [3:0] phase_prev_q;
  logic [3:0] state_prev_q;
  int         phase_match_errors;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      phase_prev_q       <= 4'd0;
      state_prev_q       <= 4'd0;
      phase_match_errors <= 0;
    end else begin
      phase_prev_q <= dut.exc_phase_index;
      state_prev_q <= 4'(dut.u_measurement_fsm.state_q);

      if (state_prev_q == ST_WAIT_P && 4'(dut.u_measurement_fsm.state_q) == ST_SAMPLE_P) begin
        if (phase_prev_q !== 4'd0) begin
          $error("PHASE_MATCH_FAIL: entered S_SAMPLE_P at phase_index=%0d, expected exactly 0",
                 phase_prev_q);
          phase_match_errors <= phase_match_errors + 1;
        end
      end

      if (state_prev_q == ST_WAIT_N && 4'(dut.u_measurement_fsm.state_q) == ST_SAMPLE_N) begin
        if (phase_prev_q !== 4'd8) begin
          $error("PHASE_MATCH_FAIL: entered S_SAMPLE_N at phase_index=%0d, expected exactly 8",
                 phase_prev_q);
          phase_match_errors <= phase_match_errors + 1;
        end
      end
    end
  end

  initial begin
    // Initialize DUT inputs.
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    cfg_pair_log2_i = 4'd2;       // 2^2 = 4 pairs
    cfg_settle_cycles_i = 8'd2;   // Rev 4.3 Phase 4: excitation PERIODS to wait after start, not raw cycles
    cfg_exc_divider_i = 14'd1;    // N=1: fastest excitation, 16 clk cycles/period
    cfg_conv_cycles_i = 8'd1;     // comparator regeneration wait per bit trial

    // Hold reset for a few cycles.
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    // Fire one measurement command pulse.
    @(posedge clk);
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    // Budget: 8 bit trials/conversion x 2 conversions/pair x 4 pairs, each
    // trial costing (3 + cfg_conv_cycles_i) cycles, plus settle/command
    // overhead -- comfortably inside 800 cycles.
    repeat (800) begin
      @(posedge clk);

      if (done_o) begin
        if (result_o !== EXPECTED_RESULT) begin
          $error("SMOKE_FAIL: expected=%0d got=%0d", EXPECTED_RESULT, result_o);
        end else if (phase_match_errors != 0) begin
          $error("SMOKE_FAIL: result correct but %0d sample(s) landed on the wrong phase_index",
                 phase_match_errors);
        end else begin
          $display("SMOKE_PASS: result=%0d (phase-match checked, 0 errors)", result_o);
        end
        $finish;
      end
    end

    $error("SMOKE_TIMEOUT: done was not asserted in expected window");
    $finish;
  end
endmodule
