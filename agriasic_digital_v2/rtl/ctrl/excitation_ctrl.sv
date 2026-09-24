// -----------------------------------------------------------------------------
// Module: excitation_ctrl
// Purpose:
//   Free-running excitation generator. Divides the master clock and drives the
//   E1 electrode continuously at a programmed frequency through the sine DAC,
//   exporting a 16-state phase counter that measurement_fsm locks its sample
//   strobes to.
//
// Rev 5 change -- square wave replaced by a sine DAC code:
//   The tetrapolar analog front end drives E1 from a sine DAC plus
//   reconstruction filter and a low-impedance buffer, not from a pair of
//   break-before-make drive transistors. This module therefore emits
//   sine_code_o (offset binary, centred on the DAC's mid-code = VCM) in place
//   of the old drive_p_o/drive_n_o pair. Everything about the PHASE machinery
//   is unchanged: same divider, same 16 states, same phase_index_o and
//   period_tick_o, so measurement_fsm's phase-match logic and the MAS timing
//   arguments carry over untouched.
//
// Frequency contract (unchanged):
//   f_exc = f_clk / (16 * N), where N = divider_i. Each of the 16 phase
//   states lasts exactly N clock cycles, so a full excitation period is
//   16*N cycles. divider_i is treated as N directly -- program the register
//   with the N a host computes from the target frequency, no off-by-one.
//
// Waveform (16-point COSINE, not sine):
//   sine_code_o[k] = MID + round((MID-1) * cos(2*pi*k/16)), so
//     k = 0  -> positive peak      (measurement_fsm's 0 deg, I positive term)
//     k = 4  -> mid-scale = VCM    (90 deg, Q positive term)
//     k = 8  -> negative peak      (180 deg, I negative term)
//     k = 12 -> mid-scale = VCM    (270 deg, Q negative term)
//   Cosine rather than sine is what makes the existing sample points correct:
//   the FSM samples at phase indices 0/4/8/12, and those must land on the
//   drive peaks (I channel) and zero crossings (Q channel) for synchronous
//   I/Q demodulation to separate the in-phase and quadrature components. A
//   sine table would put a zero crossing at index 0 and the I channel would
//   measure nothing.
//
// Half-period symmetry (the ± chop contract, preserved):
//   code[k] + code[k+8] == 2*MID for every k, exactly, by construction of the
//   table. The old square wave got this from two 7-state drive halves; the
//   cosine table gets it from the table values themselves. This is what makes
//   (D(0) - D(180)) cancel offset and drift: the two samples sit on equal and
//   opposite excursions about VCM.
//
//   There is no dead time and no break-before-make requirement any more --
//   there are no complementary drive transistors to shoot through. MAS GAP-6
//   (dead-time sizing) is retired by this change; the analog drive buffer's
//   slew and the reconstruction filter now set the transition behaviour.
//
// Harmonic content:
//   16 points per period is coarse: the reconstruction filter sees images at
//   (16 +/- 1) * f_exc and must attenuate them. PHASE_STEPS is a parameter so
//   the table can be regenerated at 32 or 64 points if the analog side needs
//   lower THD -- note that changing it also changes the frequency contract
//   (f_exc = f_clk / (PHASE_STEPS * N)) and therefore the divider presets in
//   firmware, so it is deliberately NOT a silent knob.
//
// Amplitude:
//   amplitude_i selects a binary attenuation of the excursion about mid-code
//   (0 = full scale, 1 = 1/2, 2 = 1/4, 3 = 1/8), for backing off drive at low
//   frequency where the soil impedance -- and hence the developed voltage --
//   is highest. Mid-code itself never moves, so the DC operating point of the
//   drive buffer is independent of amplitude.
//
// period_tick_o: one clk-cycle pulse per full 16-state period (on the
// phase_index wrap from 15 to 0). measurement_fsm uses this to count
// excitation periods for its post-start settle wait.
// -----------------------------------------------------------------------------
module excitation_ctrl #(
  // Rev 4.3 Phase 4.2 / GAP-1: widened from 8 to 14 bits. N=10000 (the 1 kHz
  // point) needs 14 bits; 8 could only reach a 39.2 kHz floor.
  parameter int unsigned DIVIDER_WIDTH = 14,
  parameter int unsigned DAC_WIDTH     = 8,
  parameter int unsigned PHASE_STEPS   = 16   // see the harmonic-content note
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     enable_i,
  input  logic [DIVIDER_WIDTH-1:0] divider_i,      // N: f_exc = f_clk / (16 * N)
  input  logic [1:0]               amplitude_i,    // 0 = full, 1 = 1/2, 2 = 1/4, 3 = 1/8
  output logic [DAC_WIDTH-1:0]     sine_code_o,    // offset binary, mid = VCM
  output logic [3:0]               phase_index_o,  // free-running 0..15
  output logic                     period_tick_o   // pulses once per full period
);

  localparam logic [3:0] PHASE_MAX = 4'(PHASE_STEPS - 1);
  localparam int unsigned MID      = 1 << (DAC_WIDTH - 1);      // 128 for 8 bits

  logic [DIVIDER_WIDTH-1:0] div_cnt_q;
  logic [3:0]               phase_q;

  // N must be >= 1; a programmed 0 is treated defensively as 1 (fastest
  // valid rate) rather than left as an undefined divide-by-zero shape.
  wire [DIVIDER_WIDTH-1:0] divider_eff = (divider_i == '0)
                                       ? {{(DIVIDER_WIDTH-1){1'b0}}, 1'b1}
                                       : divider_i;
  wire tick = (div_cnt_q == (divider_eff - {{(DIVIDER_WIDTH-1){1'b0}}, 1'b1}));

  assign phase_index_o = phase_q;

  // --------------------------------------------------------------------------
  // Cosine excursion table: delta[k] = round((MID-1) * cos(2*pi*k/16)).
  // Stored as signed excursions about mid-code so the +/- symmetry
  // delta[k] = -delta[k+8] is structural, and so amplitude scaling is a shift
  // of the excursion only.
  // --------------------------------------------------------------------------
  function automatic logic signed [DAC_WIDTH:0] cos_delta(input logic [3:0] idx);
    unique case (idx)
      4'd0:  return  9'sd127;
      4'd1:  return  9'sd117;
      4'd2:  return  9'sd90;
      4'd3:  return  9'sd49;
      4'd4:  return  9'sd0;
      4'd5:  return -9'sd49;
      4'd6:  return -9'sd90;
      4'd7:  return -9'sd117;
      4'd8:  return -9'sd127;
      4'd9:  return -9'sd117;
      4'd10: return -9'sd90;
      4'd11: return -9'sd49;
      4'd12: return  9'sd0;
      4'd13: return  9'sd49;
      4'd14: return  9'sd90;
      default: return 9'sd117;   // k = 15
    endcase
  endfunction

  wire signed [DAC_WIDTH:0] delta_full = cos_delta(phase_q);
  wire signed [DAC_WIDTH:0] delta_att  = delta_full >>> amplitude_i;

  // Mid-code plus the (attenuated) excursion, in one extra bit of signed
  // headroom so the sum cannot overflow before it is truncated back to the
  // DAC width. MID is zero-extended rather than cast, so the arithmetic reads
  // as "128 + delta" rather than relying on 8-bit two's-complement wraparound.
  wire signed [DAC_WIDTH:0] code_signed = $signed({1'b0, DAC_WIDTH'(MID)}) + delta_att;

  // Idle parks at mid-code (VCM): the drive buffer holds the electrode at the
  // common mode rather than at a rail when no measurement is running.
  always_comb begin
    if (!enable_i) sine_code_o = DAC_WIDTH'(MID);
    else           sine_code_o = DAC_WIDTH'(code_signed);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt_q     <= '0;
      phase_q       <= 4'd0;
      period_tick_o <= 1'b0;
    end else if (!enable_i) begin
      // Deterministic idle state: code parked at mid-scale, phase parked at 0
      // so the very first tick after enable starts a clean period rather than
      // resuming mid-cycle.
      div_cnt_q     <= '0;
      phase_q       <= 4'd0;
      period_tick_o <= 1'b0;
    end else begin
      period_tick_o <= 1'b0;

      if (tick) begin
        div_cnt_q <= '0;
        if (phase_q == PHASE_MAX) begin
          phase_q       <= 4'd0;
          period_tick_o <= 1'b1;
        end else begin
          phase_q <= phase_q + 4'd1;
        end
      end else begin
        div_cnt_q <= div_cnt_q + {{(DIVIDER_WIDTH-1){1'b0}}, 1'b1};
      end
    end
  end

`ifndef SYNTHESIS
  // The +/- chop depends on the table being exactly antisymmetric.
  initial begin
    for (int k = 0; k < 8; k++) begin
      assert (cos_delta(4'(k)) == -cos_delta(4'(k + 8)))
        else $error("excitation_ctrl: cosine table not antisymmetric at k=%0d", k);
    end
  end
`endif

endmodule
