// -----------------------------------------------------------------------------
// Module: excitation_ctrl
// Purpose:
//   Free-running excitation generator (Rev 4.3 Phase 4 -- the architectural
//   inversion). Divides the master clock and drives the electrodes
//   continuously at a programmed frequency, exporting a 16-state phase
//   counter that measurement_fsm locks its sample strobes to.
//
// What changed from Rev 4.2 / Phase 1-3:
//   The FSM used to command each polarity flip (set_phase_i/phase_value_i),
//   and this module reported back when a commanded flip had settled
//   (settled_o). That relationship is now inverted: this module runs on its
//   own from the moment enable_i is asserted, and the FSM's job becomes
//   watching phase_index_o for the instants it cares about (see
//   measurement_fsm). There is no "command" left to issue or settle after --
//   excitation is a stationary, continuously-running periodic signal, which
//   is what equivalent-time sampling (MAS section 3.2) requires in the first
//   place.
//
// Frequency contract:
//   f_exc = f_clk / (16 * N), where N = divider_i. Each of the 16 phase
//   states lasts exactly N clock cycles, so a full excitation period is
//   16*N cycles. divider_i is treated as N directly -- program the register
//   with the N a host computes from the target frequency, no off-by-one.
//   (The Rev 4.2 settle-tick divider this replaces had one: a divider_i of D
//   actually produced ticks every D+1 cycles. That was harmless for a
//   qualitative settle knob; it is not acceptable now that divider_i is a
//   precise, documented N a host derives from a frequency table -- see MAS
//   GAP-1. Fixed here, not carried forward.)
//
// Phase counter and break-before-make (Rev 4.3 Phase 1 contract, preserved):
//   16 phase states. Two of them are reserved as dead (both drive lines off)
//   so every polarity transition passes through a real off period, not just
//   a logically-exclusive instant:
//     0-6   : drive_p_o high   (positive half)
//     7     : dead (break)
//     8-14  : drive_n_o high   (negative half)
//     15    : dead (break)
//   {drive_p_o, drive_n_o} = 2'b11 remains structurally unreachable: both are
//   pure combinational functions of the same phase counter, with disjoint
//   ranges -- no register state can assert both. Dead time is exactly one
//   phase state, i.e. N clock cycles: at the fastest programmed point (N=1)
//   that is 1 cycle, matching the DEAD_CYCLES=1 default this design replaces
//   (MAS GAP-6 is still open on whether that is enough once a real
//   break-before-make number exists from analog).
//
//   Sample points (four phase offsets, 22.5 degrees apart, per the baseline
//   doc's "Contracts to freeze"): 0 deg = phase_index 0, 90 deg = 4, 180 deg
//   = 8, 270 deg = 12. This design implements 0 deg and 180 deg for now
//   (measurement_fsm's D+/D- chop, unchanged in meaning from Rev 4.2); 90/270
//   deg (the Q channel) are Phase 5 work. Phase 0 and 180 land immediately
//   after a dead state, i.e. at minimum settle margin from the transition --
//   flagged as MAS GAP-7, not silently resolved, since whether that margin is
//   sufficient depends on the real TIA/electrode settling time constant.
//
// period_tick_o: one clk-cycle pulse per full 16-state period (on the
// phase_index wrap from 15 to 0). measurement_fsm uses this to count
// excitation periods for its post-start settle wait -- see there for why
// "settle" now means something different than it did pre-Phase-4.
// -----------------------------------------------------------------------------
module excitation_ctrl #(
  // Rev 4.3 Phase 4.2 / GAP-1: widened from 8 to 14 bits. N=10000 (the 1 kHz
  // point) needs 14 bits; 8 could only reach a 39.2 kHz floor.
  parameter int unsigned DIVIDER_WIDTH = 14
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     enable_i,
  input  logic [DIVIDER_WIDTH-1:0] divider_i,      // N: f_exc = f_clk / (16*N)
  output logic                     drive_p_o,
  output logic                     drive_n_o,
  output logic [3:0]               phase_index_o,  // free-running 0..15
  output logic                     period_tick_o    // pulses once per full period
);

  localparam logic [3:0] PHASE_MAX = 4'd15;
  localparam logic [3:0] P_DEAD    = 4'd7;
  localparam logic [3:0] N_DEAD    = 4'd15;

  logic [DIVIDER_WIDTH-1:0] div_cnt_q;
  logic [3:0]               phase_q;

  // N must be >= 1; a programmed 0 is treated defensively as 1 (fastest
  // valid rate) rather than left as an undefined divide-by-zero shape.
  wire [DIVIDER_WIDTH-1:0] divider_eff = (divider_i == '0)
                                       ? {{(DIVIDER_WIDTH-1){1'b0}}, 1'b1}
                                       : divider_i;
  wire tick = (div_cnt_q == (divider_eff - {{(DIVIDER_WIDTH-1){1'b0}}, 1'b1}));

  wire in_p_half = (phase_q < P_DEAD);
  wire in_n_half = (phase_q >= 4'd8) && (phase_q != N_DEAD);

  assign drive_p_o     = enable_i & in_p_half;
  assign drive_n_o     = enable_i & in_n_half;
  assign phase_index_o = phase_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt_q     <= '0;
      phase_q       <= 4'd0;
      period_tick_o <= 1'b0;
    end else if (!enable_i) begin
      // Deterministic idle state: both drive lines low (structurally safe),
      // phase parked at 0 so the very first tick after enable starts a clean
      // period rather than resuming mid-cycle.
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

endmodule
