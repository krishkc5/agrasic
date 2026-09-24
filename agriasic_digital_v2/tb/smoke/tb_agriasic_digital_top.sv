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
  // Rev 5 two-channel model. dV (mux channel 0, PGA on E2/E3):
  //   dV(0)=220, dV(180)=100 -> I delta = 120/pair -> dv_i = 4*120 = 480
  //   dV(90)=170, dV(270)=90 -> Q delta =  80/pair -> dv_q = 4*80  = 320
  // Current (mux channel 1, TIA on E4), deliberately DIFFERENT values so a
  // swapped mux or a mis-sequenced conversion cannot pass:
  //   I(0)=200, I(180)=110  -> I delta = 90/pair  -> cur_i = 4*90 = 360
  //   I(90)=160, I(270)=100 -> Q delta = 60/pair  -> cur_q = 4*60 = 240
  // Deliberately different deltas so a channel-swap or "Q silently copies I"
  // bug would produce a numerically wrong, not just coincidentally right,
  // result.
  localparam logic signed [15:0] EXPECTED_I = 16'sd480;
  localparam logic signed [15:0] EXPECTED_Q = 16'sd320;
  localparam logic signed [15:0] EXPECTED_CUR_I = 16'sd360;
  localparam logic signed [15:0] EXPECTED_CUR_Q = 16'sd240;

  logic clk;
  logic rst_n;
  logic start;
  logic [3:0]  cfg_pair_log2_i;
  logic [7:0]  cfg_settle_cycles_i;
  logic [13:0] cfg_exc_divider_i;
  logic [7:0]  cfg_conv_cycles_i;
  logic conv_start_o;
  logic [ADC_WIDTH-1:0] sine_code_o;
  logic [1:0] mux_sel_o;
  logic adc_enable_o;
  logic adc_sample_o;
  logic [ADC_WIDTH-1:0] adc_dac_o;
  logic adc_comp_i;
  logic busy_o;
  logic done_o;
  logic signed [15:0] result_dv_i_o;
  logic signed [15:0] result_dv_q_o;
  logic signed [15:0] result_cur_i_o;
  logic signed [15:0] result_cur_q_o;

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
    .cfg_mux_settle_i(8'd2),
    .cfg_amplitude_i(2'd0),
    .afe_conv_start_o(conv_start_o),
    .afe_sine_code_o(sine_code_o),
    .afe_mux_sel_o(mux_sel_o),
    .afe_adc_enable_o(adc_enable_o),
    .afe_sample_o(adc_sample_o),
    .afe_adc_dac_o(adc_dac_o),
    .afe_adc_comp_i(adc_comp_i),
    .busy_o(busy_o),
    .done_o(done_o),
    .result_dv_i_o(result_dv_i_o),
    .result_dv_q_o(result_dv_q_o),
    .result_cur_i_o(result_cur_i_o),
    .result_cur_q_o(result_cur_q_o)
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
  // Rev 5 two-channel AFE model: dV (analog mux channel 0, PGA on E2/E3) and
  // return current (channel 1, TIA on E4). Both are frozen by the single
  // adc_sample_o strobe at the FSM's chosen phase point; the comparator then
  // answers for whichever channel mux_sel selects.
  logic [ADC_WIDTH-1:0] hold_dv_q, hold_cur_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (2'(dut.u_measurement_fsm.point_q))
        4'd0: begin hold_dv_q <= 8'd220; hold_cur_q <= 8'd200; end  // PT_0   (0 deg)
        4'd1: begin hold_dv_q <= 8'd100; hold_cur_q <= 8'd110; end  // PT_180 (180 deg)
        4'd2: begin hold_dv_q <= 8'd170; hold_cur_q <= 8'd160; end  // PT_90  (90 deg)
        4'd3: begin hold_dv_q <= 8'd90; hold_cur_q <= 8'd100; end  // PT_270 (270 deg)
        default: begin end
      endcase
    end
  end
  wire [ADC_WIDTH-1:0] adc_target = (mux_sel_o == 2'd0) ? hold_dv_q : hold_cur_q;
  assign adc_comp_i = (adc_target >= adc_dac_o);


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
  //   Rev 5 encoding: 0=S_IDLE 1=S_SETTLE 2=S_WAIT 3=S_CONV_DV 4=S_CONV_CUR
  //   5=S_ACCUM 6=S_LOOP 7=S_DONE. The four sample points now share one
  //   S_WAIT state and are told apart by point_q (0=PT_0, 1=PT_180, 2=PT_90,
  //   3=PT_270), so the check is on the S_WAIT -> S_CONV_DV transition: the
  //   phase at that instant must be exactly the one this point names.
  localparam logic [2:0] ST_WAIT    = 3'd2;
  localparam logic [2:0] ST_CONV_DV = 3'd3;

  logic [3:0] phase_prev_q;
  logic [2:0] state_prev_q;
  logic [1:0] point_prev_q;
  int         phase_match_errors;

  // Expected phase index for each point.
  function automatic logic [3:0] expected_phase(input logic [1:0] pt);
    unique case (pt)
      2'd0:    return 4'd0;    // PT_0
      2'd1:    return 4'd8;    // PT_180
      2'd2:    return 4'd4;    // PT_90
      default: return 4'd12;   // PT_270
    endcase
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      phase_prev_q       <= 4'd0;
      state_prev_q       <= 3'd0;
      point_prev_q       <= 2'd0;
      phase_match_errors <= 0;
    end else begin
      phase_prev_q <= dut.exc_phase_index;
      state_prev_q <= 3'(dut.u_measurement_fsm.state_q);
      point_prev_q <= 2'(dut.u_measurement_fsm.point_q);

      if (state_prev_q == ST_WAIT && 3'(dut.u_measurement_fsm.state_q) == ST_CONV_DV) begin
        if (phase_prev_q !== expected_phase(point_prev_q)) begin
          $error("PHASE_MATCH_FAIL: point %0d sampled at phase_index=%0d, expected exactly %0d",
                 point_prev_q, phase_prev_q, expected_phase(point_prev_q));
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
      busy_o |-> $stable(dut.u_measurement_fsm.dv_i_sh_q)  &&
                  $stable(dut.u_measurement_fsm.dv_q_sh_q)  &&
                  $stable(dut.u_measurement_fsm.cur_i_sh_q) &&
                  $stable(dut.u_measurement_fsm.cur_q_sh_q);
  endproperty
  assert property (p_shadow_stable_while_busy)
    else $error("SHADOW_FAIL: shadow register changed while busy_o was high");

  // V-5: a sample strobe may only RISE on an exact phase-index match for the
  // WAIT state it rose in -- e.g. rising in S_WAIT_0 requires phase_index_i
  // to be exactly 0 that same cycle, not merely one of the four valid
  // targets (a target-swap bug, e.g. S_WAIT_0 accidentally comparing against
  // phase 8, would still pass a weaker "matches one of the four" check).
  // dut.sample_req (measurement_fsm's sample_req_o, an internal wire -- not
  // a top-level port) is combinational on phase_index_i while in S_WAIT
  // (section 6.1), so $rose fires on the exact match cycle.
  // Rev 5: the FSM visits the four points through one shared S_WAIT state,
  // with point_q saying which; the check is that the phase matches the point
  // exactly -- a target-swap bug (e.g. PT_0 comparing against phase 8) still
  // fails. States: 2 = S_WAIT. Points: 0 = PT_0, 1 = PT_180, 2 = PT_90,
  // 3 = PT_270.
  property p_sample_req_exact_phase_match;
    @(posedge clk) disable iff (!rst_n)
      $rose(dut.sample_req) |->
        (3'(dut.u_measurement_fsm.state_q) == 3'd2) &&
        ((2'(dut.u_measurement_fsm.point_q) == 2'd0 && dut.exc_phase_index == 4'd0)  ||
         (2'(dut.u_measurement_fsm.point_q) == 2'd1 && dut.exc_phase_index == 4'd8)  ||
         (2'(dut.u_measurement_fsm.point_q) == 2'd2 && dut.exc_phase_index == 4'd4)  ||
         (2'(dut.u_measurement_fsm.point_q) == 2'd3 && dut.exc_phase_index == 4'd12));
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
  // Rev 5: all FOUR accumulators obey the same bound -- the second channel
  // does not relax it, since each accumulates its own +/-255-bounded delta.
  localparam int signed ACC_SAFE_MAX = 16320;
  property p_acc_in_range;
    @(posedge clk) disable iff (!rst_n)
      (dut.u_measurement_fsm.dv_i_q  <= ACC_SAFE_MAX) && (dut.u_measurement_fsm.dv_i_q  >= -ACC_SAFE_MAX) &&
      (dut.u_measurement_fsm.dv_q_q  <= ACC_SAFE_MAX) && (dut.u_measurement_fsm.dv_q_q  >= -ACC_SAFE_MAX) &&
      (dut.u_measurement_fsm.cur_i_q <= ACC_SAFE_MAX) && (dut.u_measurement_fsm.cur_i_q >= -ACC_SAFE_MAX) &&
      (dut.u_measurement_fsm.cur_q_q <= ACC_SAFE_MAX) && (dut.u_measurement_fsm.cur_q_q >= -ACC_SAFE_MAX);
  endproperty
  assert property (p_acc_in_range)
    else $error("ACC_RANGE_FAIL: an accumulator exceeded the +/-16320 safe bound");

  // Rev 5: the analog mux must be stable for the whole conversion it belongs
  // to -- a mux change between the settle wait and the last bit trial would
  // digitise a mixture of the two channels.
  property p_mux_stable_during_conversion;
    @(posedge clk) disable iff (!rst_n)
      (3'(dut.u_sar_controller.state_q) != 3'd0) |-> $stable(mux_sel_o);
  endproperty
  assert property (p_mux_stable_during_conversion)
    else $error("MUX_FAIL: afe_mux_sel_o changed during a conversion");

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
        if (result_dv_i_o !== EXPECTED_I) begin
          $error("SMOKE_FAIL: expected I=%0d got=%0d", EXPECTED_I, result_dv_i_o);
        end else if (result_dv_q_o !== EXPECTED_Q) begin
          $error("SMOKE_FAIL: expected Q=%0d got=%0d", EXPECTED_Q, result_dv_q_o);
        end else if (result_cur_i_o !== EXPECTED_CUR_I) begin
          $error("SMOKE_FAIL: expected cur_I=%0d got=%0d", EXPECTED_CUR_I, result_cur_i_o);
        end else if (result_cur_q_o !== EXPECTED_CUR_Q) begin
          $error("SMOKE_FAIL: expected cur_Q=%0d got=%0d", EXPECTED_CUR_Q, result_cur_q_o);
        end else if (phase_match_errors != 0) begin
          $error("SMOKE_FAIL: result correct but %0d sample(s) landed on the wrong phase_index",
                 phase_match_errors);
        end else begin
          $display("SMOKE_PASS: dV I=%0d Q=%0d  cur I=%0d Q=%0d (phase-match checked, 0 errors)",
                   result_dv_i_o, result_dv_q_o, result_cur_i_o, result_cur_q_o);
        end
        $finish;
      end
    end

    $error("SMOKE_TIMEOUT: done was not asserted in expected window");
    $finish;
  end
endmodule
