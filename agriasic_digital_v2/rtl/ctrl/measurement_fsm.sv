// -----------------------------------------------------------------------------
// Module: measurement_fsm
// Purpose:
//   Measurement sequencer -- the hard real-time inner loop.
//
// Rev 4.3 Phase 4 -- the architectural inversion (background, unchanged by
// Phase 5): this FSM used to CAUSE each excitation polarity flip and wait for
// excitation_ctrl to report it settled. Excitation is free-running now, so
// this FSM watches the free-running phase_index_i for the instants it cares
// about and strobes a sample exactly then, via sar_controller.
//
// Rev 4.3 Phase 5 -- I/Q accumulation:
//   Phase 4 only sampled the I channel (0 deg / 180 deg, phase_index 0/8).
//   Phase 5 adds the Q channel (90 deg / 270 deg, phase_index 4/12) and a
//   second signed accumulator, per section 3.1:
//     I = (D(0deg)  - D(180deg)) / 2
//     Q = (D(90deg) - D(270deg)) / 2
//   (the /2 and all further scaling stay host-side, same as Phase 1's D-3
//   fix for the single accumulator -- this FSM still accumulates raw,
//   unscaled sums.)
//
//   One pair now costs FOUR sar_controller conversions instead of two: D(0),
//   D(180) accumulate into I; D(90), D(270) accumulate into Q. D+/D- capture
//   inside sar_controller is reused as a generic "current sample slot",
//   unmodified -- sample_phase_o=1 always means "capture into the d_plus
//   slot", 0 means "capture into d_minus", regardless of which channel that
//   slot is about to feed. sar_controller has no notion of I/Q at all.
//
//   Shadow registers (section 9.3's "Accumulator snapshot" contract, first
//   implemented here): the live accumulators (i_acc_q, q_acc_q) update
//   mid-run, one pair at a time, while busy_o is high. What the host reads
//   (result_i_o, result_q_o) is a SEPARATE pair of shadow registers that only
//   latch the live accumulators' final value on the S_LOOP -> S_DONE
//   transition -- the one and only cycle busy_o drops from 1 to 0. A host
//   reading mid-run therefore always sees the previous run's complete result,
//   never a partial sum from the run in progress.
//
// settle_cycles_i (unchanged from Phase 4): counts full excitation periods
// (period_tick_i pulses) to wait after `start` before the first sample is
// trusted, not raw clock cycles.
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
  input  logic [ADC_WIDTH-1:0]    d_plus_i,
  input  logic [ADC_WIDTH-1:0]    d_minus_i,
  output logic                    exc_enable_o,
  output logic                    sample_req_o,
  output logic                    sample_phase_o,
  output logic                    busy_o,
  output logic                    done_o,
  output logic signed [ACC_WIDTH-1:0] result_i_o,
  output logic signed [ACC_WIDTH-1:0] result_q_o
);

  // Phase indices this FSM samples at -- the four 90-degree-spaced points
  // used to separate the I and Q channels. See excitation_ctrl for the full
  // 16-state phase map (0-6 positive drive, 7 dead, 8-14 negative drive, 15
  // dead); all four sample points fall on states already inside a drive half,
  // never on a dead state.
  localparam logic [3:0] PHASE_0_DEG   = 4'd0;   // I, positive term
  localparam logic [3:0] PHASE_90_DEG  = 4'd4;   // Q, positive term
  localparam logic [3:0] PHASE_180_DEG = 4'd8;   // I, negative term
  localparam logic [3:0] PHASE_270_DEG = 4'd12;  // Q, negative term

  typedef enum logic [3:0] {
    S_IDLE,
    S_SETTLE,
    S_WAIT_0,
    S_SAMPLE_0,
    S_WAIT_180,
    S_SAMPLE_180,
    S_ACCUM_I,
    S_WAIT_90,
    S_SAMPLE_90,
    S_WAIT_270,
    S_SAMPLE_270,
    S_ACCUM_Q,
    S_LOOP,
    S_DONE
  } state_t;

  state_t state_q, state_d;
  logic [PAIR_CNT_W-1:0] pair_count_q, pair_count_d;
  logic [PAIR_CNT_W-1:0] pair_target;
  logic signed [ACC_WIDTH-1:0] i_acc_q, i_acc_d;
  logic signed [ACC_WIDTH-1:0] q_acc_q, q_acc_d;
  logic signed [ACC_WIDTH-1:0] i_shadow_q, i_shadow_d;
  logic signed [ACC_WIDTH-1:0] q_shadow_q, q_shadow_d;
  logic signed [ACC_WIDTH-1:0] sample_delta;
  logic [SETTLE_W-1:0] settle_count_q, settle_count_d;

  // Rev 4.3 fix 3 (Phase 1) still applies: accumulate the RAW signed
  // difference and leave scaling to the host. M is clamped to 64 pairs;
  // worst case |delta| is 255, so either accumulator spans +/- 16320, inside
  // signed 16-bit -- unchanged by having two of them, since I and Q each
  // independently obey the same per-channel bound (section 9.3).
  assign pair_target  = (pair_log2_i >= 4'd6) ? 8'd64 : (8'd1 << pair_log2_i);
  assign sample_delta = $signed({{(ACC_WIDTH-ADC_WIDTH){1'b0}}, d_plus_i})
                      - $signed({{(ACC_WIDTH-ADC_WIDTH){1'b0}}, d_minus_i});

  // Combinational next-state/output logic.
  always_comb begin
    state_d          = state_q;
    i_acc_d          = i_acc_q;
    q_acc_d          = q_acc_q;
    i_shadow_d       = i_shadow_q;
    q_shadow_d       = q_shadow_q;
    pair_count_d     = pair_count_q;
    settle_count_d   = settle_count_q;

    exc_enable_o     = 1'b0;
    sample_req_o     = 1'b0;
    sample_phase_o   = 1'b0;

    busy_o           = 1'b0;
    done_o           = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (start_i) begin
          state_d        = S_SETTLE;
          i_acc_d        = '0;
          q_acc_d        = '0;
          pair_count_d   = '0;
          settle_count_d = '0;
        end
      end

      // Excitation just turned on (or is already running from a prior pair
      // in this same run -- see S_LOOP, which does not re-enter S_SETTLE).
      // Wait settle_cycles_i full excitation periods before trusting a
      // sample.
      S_SETTLE: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (settle_count_q >= settle_cycles_i) begin
          state_d = S_WAIT_0;
        end else if (period_tick_i) begin
          settle_count_d = settle_count_q + {{(SETTLE_W-1){1'b0}}, 1'b1};
        end
      end

      // ---- I channel: 0 degrees then 180 degrees ----
      S_WAIT_0: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (phase_index_i == PHASE_0_DEG) begin
          sample_req_o   = 1'b1;
          sample_phase_o = 1'b1;
          state_d        = S_SAMPLE_0;
        end
      end

      S_SAMPLE_0: begin
        busy_o         = 1'b1;
        exc_enable_o   = 1'b1;
        sample_req_o   = 1'b1;
        sample_phase_o = 1'b1;
        if (sar_done_i) begin
          state_d = S_WAIT_180;
        end
      end

      S_WAIT_180: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (phase_index_i == PHASE_180_DEG) begin
          sample_req_o   = 1'b1;
          sample_phase_o = 1'b0;
          state_d        = S_SAMPLE_180;
        end
      end

      S_SAMPLE_180: begin
        busy_o         = 1'b1;
        exc_enable_o   = 1'b1;
        sample_req_o   = 1'b1;
        sample_phase_o = 1'b0;
        if (sar_done_i) begin
          state_d = S_ACCUM_I;
        end
      end

      S_ACCUM_I: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        i_acc_d      = i_acc_q + sample_delta;  // d_plus_i/d_minus_i hold D(0)/D(180) here
        state_d      = S_WAIT_90;
      end

      // ---- Q channel: 90 degrees then 270 degrees ----
      S_WAIT_90: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (phase_index_i == PHASE_90_DEG) begin
          sample_req_o   = 1'b1;
          sample_phase_o = 1'b1;
          state_d        = S_SAMPLE_90;
        end
      end

      S_SAMPLE_90: begin
        busy_o         = 1'b1;
        exc_enable_o   = 1'b1;
        sample_req_o   = 1'b1;
        sample_phase_o = 1'b1;
        if (sar_done_i) begin
          state_d = S_WAIT_270;
        end
      end

      S_WAIT_270: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (phase_index_i == PHASE_270_DEG) begin
          sample_req_o   = 1'b1;
          sample_phase_o = 1'b0;
          state_d        = S_SAMPLE_270;
        end
      end

      S_SAMPLE_270: begin
        busy_o         = 1'b1;
        exc_enable_o   = 1'b1;
        sample_req_o   = 1'b1;
        sample_phase_o = 1'b0;
        if (sar_done_i) begin
          state_d = S_ACCUM_Q;
        end
      end

      S_ACCUM_Q: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        q_acc_d      = q_acc_q + sample_delta;  // d_plus_i/d_minus_i hold D(90)/D(270) here
        pair_count_d = pair_count_q + {{(PAIR_CNT_W-1){1'b0}}, 1'b1};
        state_d      = S_LOOP;
      end

      // Loop back to watching for phase 0 -- excitation keeps running
      // uninterrupted, so no re-settle is needed between pairs within one
      // run. On the final pair, snapshot both accumulators into the shadow
      // registers the host actually reads (result_i_o/result_q_o) -- this is
      // the one and only cycle that write can happen, and it happens on the
      // same edge busy_o drops, never while busy_o reads 1 (section 9.3).
      S_LOOP: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (pair_count_q >= pair_target) begin
          i_shadow_d = i_acc_q;
          q_shadow_d = q_acc_q;
          state_d    = S_DONE;
        end else begin
          state_d = S_WAIT_0;
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
      i_acc_q        <= '0;
      q_acc_q        <= '0;
      i_shadow_q     <= '0;
      q_shadow_q     <= '0;
      pair_count_q   <= '0;
      settle_count_q <= '0;
    end else begin
      state_q        <= state_d;
      i_acc_q        <= i_acc_d;
      q_acc_q        <= q_acc_d;
      i_shadow_q     <= i_shadow_d;
      q_shadow_q     <= q_shadow_d;
      pair_count_q   <= pair_count_d;
      settle_count_q <= settle_count_d;
    end
  end

  // Host-visible result: the shadow registers, never the live accumulators.
  assign result_i_o = i_shadow_q;
  assign result_q_o = q_shadow_q;

endmodule
