// -----------------------------------------------------------------------------
// Module: measurement_fsm
// Purpose:
//   Measurement sequencer and fallback controller path.
//
// Functionality:
//   - Issues positive/negative excitation phases with settle qualification.
//   - Requests D+ and D- samples from SAR controller.
//   - Accumulates (D+ - D-) / 2 for M sample pairs.
//   - Exposes busy/done and result readout.
//
// Integration intent:
//   This FSM is the guaranteed fallback if CPU-based control is descoped.
// -----------------------------------------------------------------------------
module measurement_fsm #(
  parameter int unsigned ADC_WIDTH = 8,
  parameter int unsigned ACC_WIDTH = 16,
  parameter int unsigned PAIR_CNT_W = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start_i,
  input  logic [3:0]              pair_log2_i,
  input  logic                    settled_i,
  input  logic                    sar_done_i,
  input  logic [ADC_WIDTH-1:0]    d_plus_i,
  input  logic [ADC_WIDTH-1:0]    d_minus_i,
  output logic                    exc_enable_o,
  output logic                    exc_set_phase_o,
  output logic                    exc_phase_o,
  output logic                    sample_req_o,
  output logic                    sample_phase_o,
  output logic                    busy_o,
  output logic                    done_o,
  output logic [ACC_WIDTH-1:0]    result_o
);

  typedef enum logic [3:0] {
    S_IDLE,
    S_SETTLE_P,
    S_SAMPLE_P,
    S_SETTLE_N,
    S_SAMPLE_N,
    S_ACCUM,
    S_LOOP,
    S_DONE
  } state_t;

  state_t state_q, state_d;
  logic [PAIR_CNT_W-1:0] pair_count_q, pair_count_d;
  logic [PAIR_CNT_W-1:0] pair_target;
  logic signed [ACC_WIDTH-1:0] acc_q, acc_d;
  logic signed [ACC_WIDTH:0] pair_delta;
  logic [3:0] pair_shift;

  assign pair_shift = (pair_log2_i >= PAIR_CNT_W[3:0]) ? (PAIR_CNT_W - 1) : pair_log2_i;
  assign pair_target = ({{(PAIR_CNT_W-1){1'b0}}, 1'b1} << pair_shift);
  assign pair_delta = ($signed({1'b0, d_plus_i}) - $signed({1'b0, d_minus_i})) >>> 1;

  // Combinational next-state/output logic.
  always_comb begin
    state_d          = state_q;
    acc_d            = acc_q;
    pair_count_d     = pair_count_q;

    exc_enable_o     = 1'b0;
    exc_set_phase_o  = 1'b0;
    exc_phase_o      = 1'b0;
    sample_req_o     = 1'b0;
    sample_phase_o   = 1'b0;

    busy_o           = 1'b0;
    done_o           = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (start_i) begin
          state_d      = S_SETTLE_P;
          acc_d        = '0;
          pair_count_d = '0;
        end
      end

      S_SETTLE_P: begin
        busy_o = 1'b1;
        exc_enable_o    = 1'b1;
        exc_set_phase_o = 1'b1;
        exc_phase_o     = 1'b1;
        if (settled_i) begin
          state_d = S_SAMPLE_P;
        end
      end

      S_SAMPLE_P: begin
        busy_o         = 1'b1;
        exc_enable_o   = 1'b1;
        sample_req_o   = 1'b1;
        sample_phase_o = 1'b1;
        if (sar_done_i) begin
          state_d = S_SETTLE_N;
        end
      end

      S_SETTLE_N: begin
        busy_o = 1'b1;
        exc_enable_o    = 1'b1;
        exc_set_phase_o = 1'b1;
        exc_phase_o     = 1'b0;
        if (settled_i) begin
          state_d = S_SAMPLE_N;
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
        acc_d        = acc_q + pair_delta[ACC_WIDTH-1:0];
        pair_count_d = pair_count_q + {{(PAIR_CNT_W-1){1'b0}}, 1'b1};
        state_d      = S_LOOP;
      end

      S_LOOP: begin
        busy_o       = 1'b1;
        exc_enable_o = 1'b1;
        if (pair_count_q >= pair_target) begin
          state_d = S_DONE;
        end else begin
          state_d = S_SETTLE_P;
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
      state_q      <= S_IDLE;
      acc_q        <= '0;
      pair_count_q <= '0;
    end else begin
      state_q      <= state_d;
      acc_q        <= acc_d;
      pair_count_q <= pair_count_d;
    end
  end

  // Expose accumulator directly as measurement result.
  assign result_o = acc_q[ACC_WIDTH-1:0];

endmodule
