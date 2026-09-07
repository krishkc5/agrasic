`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_agriasic_digital_top
// Purpose:
//   Smoke test for top-level digital integration -- self-checking.
//
// What this test checks:
//   1) One full 4-pair measurement run produces the exact expected raw I and
//      Q accumulated results (Rev 4.3 Phase 5).
//   2) Every sample lands on the EXACT phase_index the design doc specifies
//      (0, 4, 8, 12 -- the four 90-degree-spaced I/Q sample points), not just
//      "somewhere in the right half" -- the comparator model alone can't
//      distinguish those on its own, since a model keyed only on
//      exc_drive_p_o cannot tell phase 0 apart from phase 4 (both occur
//      while drive_p_o is high).
// -----------------------------------------------------------------------------
module tb_agriasic_digital_top;
  localparam int unsigned ADC_WIDTH = 8;
  // D(0)=220, D(180)=100 -> I delta = 120/pair -> I = 4*120 = 480
  // D(90)=170, D(270)=90 -> Q delta =  80/pair -> Q = 4*80  = 320
  // Deliberately different deltas so a channel-swap or "Q silently copies I"
  // bug would produce a numerically wrong, not just coincidentally right,
  // result.
  localparam logic signed [15:0] EXPECTED_I = 16'sd480;
  localparam logic signed [15:0] EXPECTED_Q = 16'sd320;

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
  logic signed [15:0] result_i_o;
  logic signed [15:0] result_q_o;

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
    .result_i_o(result_i_o),
    .result_q_o(result_q_o)
  );

  // 100 MHz equivalent simulation clock.
  always #5 clk = ~clk;

  // Behavioral comparator model for the Rev 4.3 SAR bit-trial interface.
  // Rev 4.3 Phase 5: four distinct targets, one per I/Q sample phase.
  //
  // Keyed on measurement_fsm's own state, NOT on exc_phase_index: sar_
  // controller's adc_sample_o pulse lands one clock cycle AFTER the phase
  // match that triggered sample_req_o (S_IDLE registers adc_sample_o<=1 the
  // cycle it ACCEPTS the request), so by the time adc_sample_o actually
  // fires, a free-running phase counter at N=1 has already ticked one state
  // past the nominal target (1/5/9/13 instead of 0/4/8/12 -- the same
  // one-cycle lag documented in MAS section 6.11's worked example). The FSM
  // state is unambiguous regardless of that lag: S_SAMPLE_0/90/180/270 each
  // mean exactly one thing, so keying on state_q sidesteps the timing
  // subtlety entirely instead of trying to compensate for it here.
  // See sar_controller's header for the adc_comp_i convention this
  // implements, and tb_agriasic_digital_top's Phase 4 history for why this
  // is track-and-hold (latched on adc_sample_o) rather than a live
  // combinational read.
  //   3=S_SAMPLE_0 5=S_SAMPLE_180 8=S_SAMPLE_90 10=S_SAMPLE_270
  //   (see the state numbering note below, by the phase-match check)
  logic [ADC_WIDTH-1:0] adc_target_held_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (4'(dut.u_measurement_fsm.state_q))
        4'd3:  adc_target_held_q <= 8'd220;  // S_SAMPLE_0:   D(0)
        4'd8:  adc_target_held_q <= 8'd170;  // S_SAMPLE_90:  D(90)
        4'd5:  adc_target_held_q <= 8'd100;  // S_SAMPLE_180: D(180)
        4'd10: adc_target_held_q <= 8'd90;   // S_SAMPLE_270: D(270)
        default: begin
          // The FSM should never request a sample from any other state.
          // Leave the held value unchanged rather than guessing, so a bug
          // here shows up as a wrong final result instead of a plausible one.
        end
      endcase
    end
  end
  assign adc_comp_i = (adc_target_held_q >= adc_dac_o);

  // --------------------------------------------------------------------------
  // Precise phase-match check (Rev 4.3 Phase 4, extended for Phase 5's four
  // sample points).
  //
  // Checks the actual phase_index at the moment each sample was requested,
  // using measurement_fsm's own state encoding hierarchically so it can't
  // silently drift out of sync with a future state reordering.
  // --------------------------------------------------------------------------
  // measurement_fsm's state_t enum, in declaration order (default SV
  // encoding: 0,1,2,...). Hierarchical access to the enum LITERALS
  // themselves crashes this Verilator version (internal fault), so this
  // compares the raw state_q value against its numeric position instead --
  // fragile only if that declaration order changes, which is exactly why
  // this comment exists.
  //   0=S_IDLE 1=S_SETTLE 2=S_WAIT_0 3=S_SAMPLE_0 4=S_WAIT_180 5=S_SAMPLE_180
  //   6=S_ACCUM_I 7=S_WAIT_90 8=S_SAMPLE_90 9=S_WAIT_270 10=S_SAMPLE_270
  //   11=S_ACCUM_Q 12=S_LOOP 13=S_DONE
  localparam logic [3:0] ST_WAIT_0     = 4'd2;
  localparam logic [3:0] ST_SAMPLE_0   = 4'd3;
  localparam logic [3:0] ST_WAIT_180   = 4'd4;
  localparam logic [3:0] ST_SAMPLE_180 = 4'd5;
  localparam logic [3:0] ST_WAIT_90    = 4'd7;
  localparam logic [3:0] ST_SAMPLE_90  = 4'd8;
  localparam logic [3:0] ST_WAIT_270   = 4'd9;
  localparam logic [3:0] ST_SAMPLE_270 = 4'd10;

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

      if (state_prev_q == ST_WAIT_0 && 4'(dut.u_measurement_fsm.state_q) == ST_SAMPLE_0) begin
        if (phase_prev_q !== 4'd0) begin
          $error("PHASE_MATCH_FAIL: entered S_SAMPLE_0 at phase_index=%0d, expected exactly 0",
                 phase_prev_q);
          phase_match_errors <= phase_match_errors + 1;
        end
      end

      if (state_prev_q == ST_WAIT_180 && 4'(dut.u_measurement_fsm.state_q) == ST_SAMPLE_180) begin
        if (phase_prev_q !== 4'd8) begin
          $error("PHASE_MATCH_FAIL: entered S_SAMPLE_180 at phase_index=%0d, expected exactly 8",
                 phase_prev_q);
          phase_match_errors <= phase_match_errors + 1;
        end
      end

      if (state_prev_q == ST_WAIT_90 && 4'(dut.u_measurement_fsm.state_q) == ST_SAMPLE_90) begin
        if (phase_prev_q !== 4'd4) begin
          $error("PHASE_MATCH_FAIL: entered S_SAMPLE_90 at phase_index=%0d, expected exactly 4",
                 phase_prev_q);
          phase_match_errors <= phase_match_errors + 1;
        end
      end

      if (state_prev_q == ST_WAIT_270 && 4'(dut.u_measurement_fsm.state_q) == ST_SAMPLE_270) begin
        if (phase_prev_q !== 4'd12) begin
          $error("PHASE_MATCH_FAIL: entered S_SAMPLE_270 at phase_index=%0d, expected exactly 12",
                 phase_prev_q);
          phase_match_errors <= phase_match_errors + 1;
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Rev 4.3 Phase 8 (V-4, V-5, and the accumulator-range half of 8.2): formal
  // assertions restating properties this smoke test already checked
  // behaviorally, plus one new structural bound. Section 9.3/12.3 previously
  // marked V-4 and V-5 "partially done" (mechanism verified by inspection or
  // by comparing registered values, no standalone `assert property`) -- these
  // close that out for real.
  // --------------------------------------------------------------------------

  // V-4: the shadow registers the host actually reads must never change while
  // busy_o is high -- the whole point of the shadow-register contract
  // (section 9.3) is that a host read mid-run sees the previous run's value,
  // never a partial sum. The only cycle they change is S_LOOP -> S_DONE, by
  // which point busy_o has already dropped (section 6.1), so this holds for
  // every cycle busy_o reads 1, not just "most of the time."
  property p_shadow_stable_while_busy;
    @(posedge clk) disable iff (!rst_n)
      busy_o |-> $stable(dut.u_measurement_fsm.i_shadow_q) &&
                  $stable(dut.u_measurement_fsm.q_shadow_q);
  endproperty
  assert property (p_shadow_stable_while_busy)
    else $error("SHADOW_FAIL: shadow register changed while busy_o was high");

  // V-5: a sample strobe may only RISE on an exact phase-index match for the
  // WAIT state it rose in -- e.g. rising in S_WAIT_0 requires phase_index_i
  // to be exactly 0 that same cycle, not merely one of the four valid
  // targets (a target-swap bug, e.g. S_WAIT_0 accidentally comparing against
  // phase 8, would still pass a weaker "matches one of the four" check).
  // dut.sample_req (measurement_fsm's sample_req_o, an internal wire -- not
  // a top-level port) is combinational on phase_index_i while in a WAIT
  // state (section 6.1), so $rose fires on the exact match cycle, not one
  // cycle later the way the state-transition-based phase_prev_q check above
  // does -- a genuinely different, cross-checking way to verify the same
  // property, not a restatement of it.
  //   2=S_WAIT_0 4=S_WAIT_180 7=S_WAIT_90 9=S_WAIT_270 (declaration order,
  //   same numbering note as the phase-match check above)
  property p_sample_req_exact_phase_match;
    @(posedge clk) disable iff (!rst_n)
      $rose(dut.sample_req) |->
        (4'(dut.u_measurement_fsm.state_q) == 4'd2 && dut.exc_phase_index == 4'd0)  ||
        (4'(dut.u_measurement_fsm.state_q) == 4'd4 && dut.exc_phase_index == 4'd8)  ||
        (4'(dut.u_measurement_fsm.state_q) == 4'd7 && dut.exc_phase_index == 4'd4)  ||
        (4'(dut.u_measurement_fsm.state_q) == 4'd9 && dut.exc_phase_index == 4'd12);
  endproperty
  assert property (p_sample_req_exact_phase_match)
    else $error("SAMPLE_REQ_FAIL: sample_req_o rose without an exact phase-index match for its state");

  // 8.2 accumulator range: structurally, M is clamped to 64 (pair_target,
  // section 6.1) and each per-pair delta is bounded by the 8-bit ADC's
  // +/-255 span, so neither accumulator can exceed +/-16320 (section 9.3) --
  // regardless of what pair_log2_i is configured to. This is a genuine
  // safety-margin check, not a restatement of the clamp: it would catch a
  // bug in the clamp itself, or a wider ADC_WIDTH parameterization that
  // widened the per-pair delta without re-deriving this bound.
  localparam int signed ACC_SAFE_MAX = 16320;
  property p_i_acc_in_range;
    @(posedge clk) disable iff (!rst_n)
      (dut.u_measurement_fsm.i_acc_q <= ACC_SAFE_MAX) &&
      (dut.u_measurement_fsm.i_acc_q >= -ACC_SAFE_MAX);
  endproperty
  property p_q_acc_in_range;
    @(posedge clk) disable iff (!rst_n)
      (dut.u_measurement_fsm.q_acc_q <= ACC_SAFE_MAX) &&
      (dut.u_measurement_fsm.q_acc_q >= -ACC_SAFE_MAX);
  endproperty
  assert property (p_i_acc_in_range)
    else $error("ACC_RANGE_FAIL: i_acc_q exceeded the +/-16320 safe bound");
  assert property (p_q_acc_in_range)
    else $error("ACC_RANGE_FAIL: q_acc_q exceeded the +/-16320 safe bound");

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

    // Budget: 8 bit trials/conversion x 4 conversions/pair (Phase 5: I and Q
    // each need two) x 4 pairs, each trial costing (3 + cfg_conv_cycles_i)
    // cycles, plus settle/command overhead -- comfortably inside 1600 cycles.
    repeat (1600) begin
      @(posedge clk);

      if (done_o) begin
        if (result_i_o !== EXPECTED_I) begin
          $error("SMOKE_FAIL: expected I=%0d got=%0d", EXPECTED_I, result_i_o);
        end else if (result_q_o !== EXPECTED_Q) begin
          $error("SMOKE_FAIL: expected Q=%0d got=%0d", EXPECTED_Q, result_q_o);
        end else if (phase_match_errors != 0) begin
          $error("SMOKE_FAIL: result correct but %0d sample(s) landed on the wrong phase_index",
                 phase_match_errors);
        end else begin
          $display("SMOKE_PASS: I=%0d Q=%0d (phase-match checked, 0 errors)", result_i_o, result_q_o);
        end
        $finish;
      end
    end

    $error("SMOKE_TIMEOUT: done was not asserted in expected window");
    $finish;
  end
endmodule
