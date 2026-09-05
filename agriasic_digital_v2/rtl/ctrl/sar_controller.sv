// -----------------------------------------------------------------------------
// Module: sar_controller
// Purpose:
//   Runs the successive-approximation bit-trial search and bridges the result
//   to digital measurement sequencing.
//
// Rev 4.3 change -- bit trials moved into digital:
//   The earlier version received a finished code on adc_code_i from a
//   self-contained converter. Rev 4.3 replaces that with the real SAR
//   interface: this controller drives the trial DAC code on adc_dac_o and
//   reads one comparator decision at a time on adc_comp_i, MSB first, exactly
//   as a real successive-approximation ADC is sequenced.
//
// adc_comp_i convention (drive the analog testbench/model to this contract):
//   1 = input >= current trial code   (keep this bit set, current code stays
//       a valid lower bound, move to the next bit)
//   0 = input <  current trial code   (clear this bit, it overshot)
//   adc_comp_i is NOT synchronized -- it is a timed path. This controller
//   guarantees comparator regeneration time (conv_cycles_i cycles) between
//   presenting a trial code and sampling the decision; it is the caller's
//   responsibility that conv_cycles_i covers the real regeneration time.
//
// conv_cycles_i meaning changed with the interface:
//   Previously "total cycles before reading one finished code." Now it is the
//   regeneration wait PER BIT TRIAL (8 trials per sample, so total conversion
//   time is 8 * (1 + conv_cycles_i) cycles). Making this a runtime register
//   rather than a fixed parameter is deliberate: comparator regeneration time
//   depends on process corner and is not yet characterized (MAS GAP-2) --
//   REG_CONV lets it be tuned during bring-up without a respin.
//
// Functionality:
//   - Accepts one sample request at a time.
//   - Asserts conv_start_o for one cycle when a request is accepted, together
//     with a one-cycle adc_sample_o track-and-hold strobe.
//   - Asserts adc_enable_o for the full conversion (accept through done).
//   - Runs 8 bit trials MSB first, each gated by conv_cycles_i regeneration
//     cycles, to build the digitized code entirely from adc_comp_i decisions.
//   - Stores the converged code in D+ or D- register based on sample_phase_i.
//   - Pulses sample_done_o when a capture completes.
//
// sample_phase_i encoding:
//   1'b1: positive phase sample (D+)
//   1'b0: negative phase sample (D-)
// -----------------------------------------------------------------------------
module sar_controller #(
  parameter int unsigned ADC_WIDTH = 8
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 sample_req_i,
  input  logic                 sample_phase_i,
  input  logic [7:0]           conv_cycles_i,
  output logic                 conv_start_o,
  output logic                 sample_done_o,
  output logic                 busy_o,
  output logic [ADC_WIDTH-1:0] d_plus_o,
  output logic [ADC_WIDTH-1:0] d_minus_o,

  // Rev 4.3 SAR bit-trial interface. adc_comp_i is a timed, unsynchronized
  // path -- see the header note on the regeneration-time contract.
  output logic                 adc_enable_o,
  output logic                 adc_sample_o,
  output logic [ADC_WIDTH-1:0] adc_dac_o,
  input  logic                 adc_comp_i
);

  localparam int unsigned BIT_IDX_W = (ADC_WIDTH <= 1) ? 1 : $clog2(ADC_WIDTH);

  typedef enum logic [1:0] {
    S_IDLE,
    S_TRIAL_SET,   // present the trial code, load the regeneration counter
    S_TRIAL_WAIT,  // wait out comparator regeneration time
    S_TRIAL_EVAL   // sample adc_comp_i, decide the bit, advance or finish
  } state_t;

  state_t                     state_q;
  logic [BIT_IDX_W-1:0]       bit_idx_q;
  logic [ADC_WIDTH-1:0]       dac_reg_q;   // decided bits only (0 below/at bit_idx_q until resolved)
  logic [7:0]                 regen_cnt_q;
  logic                       phase_q;

  // Trial mask for the bit currently under test, and the code that would
  // result from EITHER decision -- computed combinationally so the last bit's
  // decision can be captured the same cycle it is made, with no one-cycle lag
  // between the register update and the value stored into d_plus_o/d_minus_o.
  logic [ADC_WIDTH-1:0] trial_mask;
  logic [ADC_WIDTH-1:0] eval_code;
  assign trial_mask = ({{(ADC_WIDTH-1){1'b0}}, 1'b1} << bit_idx_q);
  assign eval_code  = adc_comp_i ? (dac_reg_q | trial_mask) : dac_reg_q;

  // adc_dac_o presents the trial code (decided bits plus the bit under test)
  // for every state past acceptance; at idle it holds the last converged code,
  // a deterministic and harmless value since adc_enable_o is low.
  assign adc_dac_o = (state_q == S_IDLE) ? dac_reg_q : (dac_reg_q | trial_mask);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q       <= S_IDLE;
      conv_start_o  <= 1'b0;
      adc_sample_o  <= 1'b0;
      adc_enable_o  <= 1'b0;
      sample_done_o <= 1'b0;
      busy_o        <= 1'b0;
      phase_q       <= 1'b0;
      bit_idx_q     <= '1;
      dac_reg_q     <= '0;
      regen_cnt_q   <= 8'd0;
      d_plus_o      <= '0;
      d_minus_o     <= '0;
    end else begin
      conv_start_o  <= 1'b0;
      adc_sample_o  <= 1'b0;
      sample_done_o <= 1'b0;

      unique case (state_q)
        S_IDLE: begin
          // Do not accept a new request in the same cycle a completion is
          // being reported. The measurement FSM holds sample_req_i high until
          // it observes sample_done_o, so without this guard the controller
          // would immediately launch a second, spurious conversion the cycle
          // after finishing -- sampling after the excitation polarity may
          // already have moved on, corrupting d_plus/d_minus.
          if (sample_req_i && !sample_done_o) begin
            busy_o       <= 1'b1;
            adc_enable_o <= 1'b1;
            adc_sample_o <= 1'b1;   // track-and-hold: capture the input now
            phase_q      <= sample_phase_i;
            conv_start_o <= 1'b1;
            bit_idx_q    <= BIT_IDX_W'(ADC_WIDTH - 1);
            dac_reg_q    <= '0;
            state_q      <= S_TRIAL_SET;
          end
        end

        S_TRIAL_SET: begin
          // adc_dac_o already presents this trial combinationally (see the
          // assign above); this state just loads the regeneration wait.
          regen_cnt_q <= conv_cycles_i;
          state_q     <= S_TRIAL_WAIT;
        end

        S_TRIAL_WAIT: begin
          if (regen_cnt_q == 8'd0) begin
            state_q <= S_TRIAL_EVAL;
          end else begin
            regen_cnt_q <= regen_cnt_q - 8'd1;
          end
        end

        S_TRIAL_EVAL: begin
          dac_reg_q <= eval_code;
          if (bit_idx_q == '0) begin
            // Last bit decided: eval_code is the converged result.
            if (phase_q) begin
              d_plus_o <= eval_code;
            end else begin
              d_minus_o <= eval_code;
            end
            busy_o        <= 1'b0;
            adc_enable_o  <= 1'b0;
            sample_done_o <= 1'b1;
            state_q       <= S_IDLE;
          end else begin
            bit_idx_q <= bit_idx_q - 1'b1;
            state_q   <= S_TRIAL_SET;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
