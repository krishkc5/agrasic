// -----------------------------------------------------------------------------
// Module: measurement_fsm
// Purpose:
//   Measurement sequencer -- the hard real-time inner loop.
//
// Rev 4.3 Phase 4 -- the architectural inversion (background): this FSM used
// to CAUSE each excitation polarity flip and wait for excitation_ctrl to
// report it settled. Excitation is free-running now, so this FSM watches the
// free-running phase_index_i for the instants it cares about and strobes a
// sample exactly then, via sar_controller.
//
// Rev 4.3 Phase 5 -- I/Q accumulation (background):
//     I = (D(0deg)  - D(180deg)) / 2
//     Q = (D(90deg) - D(270deg)) / 2
//   (the /2 and all further scaling stay host-side; this FSM accumulates raw,
//   unscaled sums.)
//
// Rev 5 -- TWO CHANNELS, ONE CONVERTER:
//   The tetrapolar front end measures two quantities at once: the differential
//   voltage across the inner electrodes (PGA on E2/E3) and the current
//   returning through the outer one (TIA on E4). Impedance is their ratio,
//   Z(f) = dV(f) / I(f), computed host-side from four accumulators:
//     dv_i  = sum( dV(0deg)  - dV(180deg) )
//     dv_q  = sum( dV(90deg) - dV(270deg) )
//     cur_i = sum(  I(0deg)  -  I(180deg) )
//     cur_q = sum(  I(90deg) -  I(270deg) )
//
//   Acquisition versus conversion. At each of the four phase points this FSM
//   issues ONE sample-and-hold strobe (sar_controller's take_sample_i = 1 on
//   the first conversion), which freezes BOTH channels at that instant, and
//   then runs TWO conversions through the analog mux -- dV first, then
//   current, the second with take_sample_i = 0 so it digitises the value
//   already held. The voltage/current phase relationship is therefore set by
//   the shared strobe, not by the conversion order: only the digitising is
//   sequential, and a skew there costs nothing. The alternative considered
//   (measure dV on one excitation period and I on the next) needs one fewer
//   sample-and-hold but assumes the soil and the drive are stationary across
//   adjacent periods, which is a much weaker claim at the 1 kHz point where a
//   period is a millisecond.
//
//   Cost: one pair is now EIGHT conversions (4 phase points x 2 channels)
//   instead of four. The settle time at low frequency dominates the
//   measurement anyway.
//
//   Accumulator bound is unchanged per accumulator: M is clamped to 64 pairs
//   and worst-case |delta| is 255, so each of the four spans +/- 16320, inside
//   signed 16-bit (section 9.3).
//
//   Shadow registers (section 9.3's "Accumulator snapshot" contract): the live
//   accumulators update mid-run while busy_o is high. What the host reads is a
//   SEPARATE set of shadow registers that only latch on the S_LOOP -> S_DONE
//   transition -- the one and only cycle busy_o drops from 1 to 0. A host
//   reading mid-run therefore always sees the previous run's complete result,
//   never a partial sum. All four accumulators snapshot on that same edge, so
//   the dV and I results a host divides are always from the same run.
//
// settle_cycles_i (unchanged): counts full excitation periods (period_tick_i
// pulses) to wait after `start` before the first sample is trusted, not raw
// clock cycles.
// -----------------------------------------------------------------------------
module measurement_fsm #(
  parameter int unsigned ADC_WIDTH   = 8,
  parameter int unsigned ACC_WIDTH   = 16,
  parameter int unsigned PAIR_CNT_W  = 8,
  parameter int unsigned SETTLE_W    = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start_i,
  input  logic [3:0]              pair_log2_i,
  input  logic [SETTLE_W-1:0]     settle_cycles_i,  // excitation PERIODS, see header
  input  logic [3:0]              phase_index_i,
  input  logic                    period_tick_i,
  input  logic                    sar_done_i,
  input  logic [ADC_WIDTH-1:0]    code_i,           // converged code from sar_controller
  output logic                    exc_enable_o,
  output logic                    sample_req_o,
  output logic                    take_sample_o,    // 1: strobe both S/H, 0: convert held value
  output logic [1:0]              channel_o,        // analog mux select
  output logic                    busy_o,
  output logic                    done_o,
  output logic signed [ACC_WIDTH-1:0] result_dv_i_o,
  output logic signed [ACC_WIDTH-1:0] result_dv_q_o,
  output logic signed [ACC_WIDTH-1:0] result_cur_i_o,
  output logic signed [ACC_WIDTH-1:0] result_cur_q_o
);

  // Phase indices this FSM samples at -- the four 90-degree-spaced points used
  // to separate the I and Q components. excitation_ctrl's cosine table puts
  // the drive peaks at 0/8 (the I terms) and the zero crossings at 4/12 (the Q
  // terms), which is what makes synchronous demodulation separate them.
  localparam logic [3:0] PHASE_0_DEG   = 4'd0;   // I, positive term
  localparam logic [3:0] PHASE_90_DEG  = 4'd4;   // Q, positive term
  localparam logic [3:0] PHASE_180_DEG = 4'd8;   // I, negative term
  localparam logic [3:0] PHASE_270_DEG = 4'd12;  // Q, negative term

  // Analog mux channels. Must match the analog front end's mux ordering.
  localparam logic [1:0] CH_DV   = 2'd0;   // differential voltage, PGA on E2/E3
  localparam logic [1:0] CH_CUR  = 2'd1;   // return current, TIA on E4

  // The four sample points, in the order they are visited. Each is one
  // sample-and-hold strobe followed by two conversions.
  localparam logic [1:0] PT_0   = 2'd0;
  localparam logic [1:0] PT_180 = 2'd1;
  localparam logic [1:0] PT_90  = 2'd2;
  localparam logic [1:0] PT_270 = 2'd3;

  typedef enum logic [2:0] {
    S_IDLE,
    S_SETTLE,
    S_WAIT,       // watch phase_index_i for this point's phase
    S_CONV_DV,    // strobe both S/H (first conversion), digitise dV
    S_CONV_CUR,   // digitise the held current sample
    S_ACCUM,      // fold this point into the accumulators
    S_LOOP,
    S_DONE
  } state_t;

  state_t state_q, state_d;
  logic [1:0] point_q, point_d;                     // which of the four phase points
  logic [PAIR_CNT_W-1:0] pair_count_q, pair_count_d;
  logic [PAIR_CNT_W-1:0] pair_target;

  // Live accumulators and their host-visible shadows.
  logic signed [ACC_WIDTH-1:0] dv_i_q,  dv_i_d,  dv_q_q,  dv_q_d;
  logic signed [ACC_WIDTH-1:0] cur_i_q, cur_i_d, cur_q_q, cur_q_d;
  logic signed [ACC_WIDTH-1:0] dv_i_sh_q,  dv_i_sh_d,  dv_q_sh_q,  dv_q_sh_d;
  logic signed [ACC_WIDTH-1:0] cur_i_sh_q, cur_i_sh_d, cur_q_sh_q, cur_q_sh_d;

  // The positive-term codes of the pair in flight, held until the matching
  // negative-term point completes (0 deg waits for 180 deg, 90 for 270).
  logic [ADC_WIDTH-1:0] dv_hold_q,  dv_hold_d;
  logic [ADC_WIDTH-1:0] cur_hold_q, cur_hold_d;
  // Codes captured at the point currently being processed.
  logic [ADC_WIDTH-1:0] dv_code_q,  dv_code_d;
  logic [ADC_WIDTH-1:0] cur_code_q, cur_code_d;

  logic [SETTLE_W-1:0] settle_count_q, settle_count_d;

  assign pair_target = (pair_log2_i >= 4'd6) ? 8'd64 : (8'd1 << pair_log2_i);

  // Target phase for the point being visited.
  logic [3:0] target_phase;
  always_comb begin
    unique case (point_q)
      PT_0:    target_phase = PHASE_0_DEG;
      PT_180:  target_phase = PHASE_180_DEG;
      PT_90:   target_phase = PHASE_90_DEG;
      default: target_phase = PHASE_270_DEG;
    endcase
  end

  // Signed difference of this point's codes against the held positive terms.
  function automatic logic signed [ACC_WIDTH-1:0] delta(input logic [ADC_WIDTH-1:0] pos,
                                                        input logic [ADC_WIDTH-1:0] neg);
    return $signed({{(ACC_WIDTH-ADC_WIDTH){1'b0}}, pos})
         - $signed({{(ACC_WIDTH-ADC_WIDTH){1'b0}}, neg});
  endfunction

  // Combinational next-state/output logic.
  always_comb begin
    state_d        = state_q;
    point_d        = point_q;
    dv_i_d         = dv_i_q;
    dv_q_d         = dv_q_q;
    cur_i_d        = cur_i_q;
    cur_q_d        = cur_q_q;
    dv_i_sh_d      = dv_i_sh_q;
    dv_q_sh_d      = dv_q_sh_q;
    cur_i_sh_d     = cur_i_sh_q;
    cur_q_sh_d     = cur_q_sh_q;
    dv_hold_d      = dv_hold_q;
    cur_hold_d     = cur_hold_q;
    dv_code_d      = dv_code_q;
    cur_code_d     = cur_code_q;
    pair_count_d   = pair_count_q;
    settle_count_d = settle_count_q;

    exc_enable_o   = 1'b0;
    sample_req_o   = 1'b0;
    take_sample_o  = 1'b0;
    channel_o      = CH_DV;

    busy_o         = 1'b0;
    done_o         = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (start_i) begin
          state_d        = S_SETTLE;
          dv_i_d         = '0;
          dv_q_d         = '0;
          cur_i_d        = '0;
          cur_q_d        = '0;
          point_d        = PT_0;
          pair_count_d   = '0;
          settle_count_d = '0;
        end
      end

      // Excitation just turned on (or is already running from a prior pair in
      // this same run -- see S_LOOP, which does not re-enter S_SETTLE). Wait
      // settle_cycles_i full excitation periods before trusting a sample.
      S_SETTLE: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (settle_count_q >= settle_cycles_i) begin
          state_d = S_WAIT;
        end else if (period_tick_i) begin
          settle_count_d = settle_count_q + {{(SETTLE_W-1){1'b0}}, 1'b1};
        end
      end

      // Watch for this point's phase. On the match, request the dV conversion
      // WITH the sample strobe: that one strobe freezes both channels here.
      S_WAIT: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        channel_o    = CH_DV;
        if (phase_index_i == target_phase) begin
          sample_req_o  = 1'b1;
          take_sample_o = 1'b1;
          state_d       = S_CONV_DV;
        end
      end

      S_CONV_DV: begin
        busy_o        = 1'b1;
        exc_enable_o  = 1'b1;
        sample_req_o  = 1'b1;
        take_sample_o = 1'b1;
        channel_o     = CH_DV;
        if (sar_done_i) begin
          dv_code_d = code_i;
          state_d   = S_CONV_CUR;
        end
      end

      // Second conversion of the pair: no new strobe, the current channel's
      // S/H still holds the value captured at the same instant as dV.
      S_CONV_CUR: begin
        busy_o        = 1'b1;
        exc_enable_o  = 1'b1;
        sample_req_o  = 1'b1;
        take_sample_o = 1'b0;
        channel_o     = CH_CUR;
        if (sar_done_i) begin
          cur_code_d = code_i;
          state_d    = S_ACCUM;
        end
      end

      // Fold this point in. The positive-term points (0 deg, 90 deg) only
      // stash their codes; the negative-term points complete the difference
      // and accumulate it.
      S_ACCUM: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        unique case (point_q)
          PT_0: begin
            dv_hold_d  = dv_code_q;
            cur_hold_d = cur_code_q;
            point_d    = PT_180;
            state_d    = S_WAIT;
          end
          PT_180: begin
            dv_i_d     = dv_i_q  + delta(dv_hold_q,  dv_code_q);
            cur_i_d    = cur_i_q + delta(cur_hold_q, cur_code_q);
            point_d    = PT_90;
            state_d    = S_WAIT;
          end
          PT_90: begin
            dv_hold_d  = dv_code_q;
            cur_hold_d = cur_code_q;
            point_d    = PT_270;
            state_d    = S_WAIT;
          end
          default: begin  // PT_270
            dv_q_d       = dv_q_q  + delta(dv_hold_q,  dv_code_q);
            cur_q_d      = cur_q_q + delta(cur_hold_q, cur_code_q);
            pair_count_d = pair_count_q + {{(PAIR_CNT_W-1){1'b0}}, 1'b1};
            point_d      = PT_0;
            state_d      = S_LOOP;
          end
        endcase
      end

      // Loop back to the first phase point -- excitation keeps running
      // uninterrupted, so no re-settle is needed between pairs within one run.
      // On the final pair, snapshot all four accumulators into the shadow
      // registers the host reads. This is the one and only cycle that write
      // can happen, and it happens on the same edge busy_o drops.
      S_LOOP: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (pair_count_q >= pair_target) begin
          dv_i_sh_d  = dv_i_q;
          dv_q_sh_d  = dv_q_q;
          cur_i_sh_d = cur_i_q;
          cur_q_sh_d = cur_q_q;
          state_d    = S_DONE;
        end else begin
          state_d = S_WAIT;
        end
      end

      S_DONE: begin
        done_o = 1'b1;
        if (!start_i) begin
          state_d = S_IDLE;
        end
      end

      default: state_d = S_IDLE;
    endcase
  end

  // State and accumulator registers.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= S_IDLE;
      point_q        <= PT_0;
      dv_i_q         <= '0;
      dv_q_q         <= '0;
      cur_i_q        <= '0;
      cur_q_q        <= '0;
      dv_i_sh_q      <= '0;
      dv_q_sh_q      <= '0;
      cur_i_sh_q     <= '0;
      cur_q_sh_q     <= '0;
      dv_hold_q      <= '0;
      cur_hold_q     <= '0;
      dv_code_q      <= '0;
      cur_code_q     <= '0;
      pair_count_q   <= '0;
      settle_count_q <= '0;
    end else begin
      state_q        <= state_d;
      point_q        <= point_d;
      dv_i_q         <= dv_i_d;
      dv_q_q         <= dv_q_d;
      cur_i_q        <= cur_i_d;
      cur_q_q        <= cur_q_d;
      dv_i_sh_q      <= dv_i_sh_d;
      dv_q_sh_q      <= dv_q_sh_d;
      cur_i_sh_q     <= cur_i_sh_d;
      cur_q_sh_q     <= cur_q_sh_d;
      dv_hold_q      <= dv_hold_d;
      cur_hold_q     <= cur_hold_d;
      dv_code_q      <= dv_code_d;
      cur_code_q     <= cur_code_d;
      pair_count_q   <= pair_count_d;
      settle_count_q <= settle_count_d;
    end
  end

  // Host-visible results: the shadow registers, never the live accumulators.
  assign result_dv_i_o  = dv_i_sh_q;
  assign result_dv_q_o  = dv_q_sh_q;
  assign result_cur_i_o = cur_i_sh_q;
  assign result_cur_q_o = cur_q_sh_q;

endmodule
