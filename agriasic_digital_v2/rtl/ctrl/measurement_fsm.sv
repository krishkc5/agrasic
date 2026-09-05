// -----------------------------------------------------------------------------
// Module: measurement_fsm
// Purpose:
//   Measurement sequencer -- the hard real-time inner loop.
//
// Rev 4.3 Phase 4 -- the architectural inversion:
//   This FSM used to CAUSE each excitation polarity flip (exc_set_phase_o/
//   exc_phase_o) and wait for excitation_ctrl to report the commanded flip
//   settled (settled_i). Excitation is now free-running (see
//   excitation_ctrl), so there is nothing left to command. This FSM's job
//   inverts to matching: it watches the free-running phase_index_i for the
//   two instants it cares about and strobes a sample exactly then.
//
//   D+ is sampled at phase_index 0 (0 degrees), D- at phase_index 8
//   (180 degrees) -- the same two-phase chop as Rev 4.2, just now driven by
//   watching a phase counter instead of commanding a flip. The other two
//   phase offsets (90/270 degrees, phase_index 4/12) are the Q channel --
//   Phase 5 work, not implemented here; this FSM still accumulates one
//   result, not two.
//
//   If phase_index_i already equals a target when a WAIT state is entered,
//   the strobe fires immediately; otherwise it waits for the next
//   occurrence, up to one full excitation period later. Both are correct --
//   equivalent-time sampling means any occurrence of a given phase is a
//   valid sample instant, not just the "next" one after a command.
//
// settle_cycles_i changed meaning, not name (same pattern as Rev 4.3 Phase 1
// reinterpreting conv_cycles_i without renaming REG_CONV):
//   Previously: raw clock cycles to wait after a commanded flip before
//   trusting a sample. Excitation no longer flips on command, so that
//   framing no longer applies. Now: the number of FULL EXCITATION PERIODS
//   (counted via period_tick_i) to wait after `start` before the first
//   sample is trusted -- a startup guard for the case where excitation was
//   just enabled from idle (see exc_enable_o below) and needs a moment to
//   reach steady state. settle_cycles_i=0 skips this wait entirely.
//
// Functionality (unchanged from Rev 4.2 in the parts Phase 4 does not touch):
//   - Requests D+ and D- samples from sar_controller.
//   - Accumulates the raw signed (D+ - D-) over M sample pairs. Scaling by M
//     is the host's job.
//   - Exposes busy/done and result readout.
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
  input  logic [SETTLE_W-1:0]     settle_cycles_i,  // excitation PERIODS now, see header
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
  output logic [ACC_WIDTH-1:0]    result_o
);

  // Phase indices this FSM samples at -- 0 and 180 degrees (the I channel).
  // See excitation_ctrl for the full 16-state phase map.
  localparam logic [3:0] P_PHASE_IDX = 4'd0;
  localparam logic [3:0] N_PHASE_IDX = 4'd8;

  typedef enum logic [3:0] {
    S_IDLE,
    S_SETTLE,
    S_WAIT_P,
    S_SAMPLE_P,
    S_WAIT_N,
    S_SAMPLE_N,
    S_ACCUM,
    S_LOOP,
    S_DONE
  } state_t;

  state_t state_q, state_d;
  logic [PAIR_CNT_W-1:0] pair_count_q, pair_count_d;
  logic [PAIR_CNT_W-1:0] pair_target;
  logic signed [ACC_WIDTH-1:0] acc_q, acc_d;
  logic signed [ACC_WIDTH-1:0] pair_delta;
  logic [SETTLE_W-1:0] settle_count_q, settle_count_d;

  // Rev 4.3 fix 3 (Phase 1, unchanged): accumulate the RAW signed difference
  // and leave scaling to the host. M is clamped to 64 pairs; worst case
  // |delta| is 255, so the accumulator spans +/- 16320, inside signed 16-bit.
  // Both codes are zero-extended to the full accumulator width before the
  // subtraction, so the difference is signed without truncation.
  assign pair_target = (pair_log2_i >= 4'd6) ? 8'd64 : (8'd1 << pair_log2_i);
  assign pair_delta  = $signed({{(ACC_WIDTH-ADC_WIDTH){1'b0}}, d_plus_i})
                     - $signed({{(ACC_WIDTH-ADC_WIDTH){1'b0}}, d_minus_i});

  // Combinational next-state/output logic.
  always_comb begin
    state_d          = state_q;
    acc_d            = acc_q;
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
          acc_d          = '0;
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
          state_d = S_WAIT_P;
        end else if (period_tick_i) begin
          settle_count_d = settle_count_q + {{(SETTLE_W-1){1'b0}}, 1'b1};
        end
      end

      // Watch for the 0-degree phase instant. Fires immediately if
      // phase_index_i already matches.
      S_WAIT_P: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (phase_index_i == P_PHASE_IDX) begin
          sample_req_o   = 1'b1;
          sample_phase_o = 1'b1;
          state_d        = S_SAMPLE_P;
        end
      end

      S_SAMPLE_P: begin
        busy_o         = 1'b1;
        exc_enable_o   = 1'b1;
        sample_req_o   = 1'b1;
        sample_phase_o = 1'b1;
        if (sar_done_i) begin
          state_d = S_WAIT_N;
        end
      end

      // Watch for the 180-degree phase instant.
      S_WAIT_N: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (phase_index_i == N_PHASE_IDX) begin
          sample_req_o   = 1'b1;
          sample_phase_o = 1'b0;
          state_d        = S_SAMPLE_N;
        end
      end

      S_SAMPLE_N: begin
        busy_o         = 1'b1;
        exc_enable_o   = 1'b1;
        sample_req_o   = 1'b1;
        sample_phase_o = 1'b0;
        if (sar_done_i) begin
          state_d = S_ACCUM;
        end
      end

      S_ACCUM: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        acc_d        = acc_q + pair_delta;
        pair_count_d = pair_count_q + {{(PAIR_CNT_W-1){1'b0}}, 1'b1};
        state_d      = S_LOOP;
      end

      // Loop back to watching for phase 0 -- excitation keeps running
      // uninterrupted, so no re-settle is needed between pairs within one
      // run.
      S_LOOP: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (pair_count_q >= pair_target) begin
          state_d = S_DONE;
        end else begin
          state_d = S_WAIT_P;
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
      acc_q          <= '0;
      pair_count_q   <= '0;
      settle_count_q <= '0;
    end else begin
      state_q        <= state_d;
      acc_q          <= acc_d;
      pair_count_q   <= pair_count_d;
      settle_count_q <= settle_count_d;
    end
  end

  // Expose accumulator directly as measurement result.
  assign result_o = acc_q[ACC_WIDTH-1:0];

endmodule
