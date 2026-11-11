// -----------------------------------------------------------------------------
// Module: agriasic_afe_top   (BEHAVIOURAL VIEW -- SIMULATION ONLY)
//
// ONE CELL. The analog front-end is a single hard macro: one blackbox to
// synthesis, one .lib, one LEF, one GDS. Synthesis never reads this file --
// it resolves the instance from lib/agriasic_afe_top.lib instead. See
// rtl/analog/README.md for how the two views are selected.
//
// Everything below the boundary is model scaffolding, not a claim about how
// the real macro is built inside. The afe_beh_* modules exist only so the
// signal chain is readable and so the bench can reach a diagnostic by
// hierarchical name; they are deliberately named so they cannot be confused
// with, or collide with, the analog team's real cell names. When the vendor
// Verilog view arrives, this entire file is removed -- nothing else changes.
//
// THE DIGITAL BOUNDARY IS A CONTRACT. It is exactly the eight signals of
// docs/interface_contract.md, "Analog front-end interface (Rev 5,
// tetrapolar)", and nothing else. Adding a pin here is a contract change,
// and the analog top must match this port list for the wrapper to link.
//
// What this model is for, beyond running: it makes the unwritten parts of
// the analog/digital boundary fail loudly instead of silently. The checks at
// the bottom are the point of the exercise -- docs/analog_integration_gaps.md
// explains each one.
//
// Electrical constants live in agriasic_afe_pkg.sv, which is kept separate
// on purpose: the bench needs the LSB size and the reference voltages to
// report errors in LSBs, and those outlive this model.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

// =============================================================================
// Model-internal blocks. Prefix afe_beh_ = behavioural scaffolding.
// =============================================================================

// -----------------------------------------------------------------------------
// Excitation sine DAC and E1 drive buffer.
//
// Contract pin: afe_sine_code_o[7:0] -- offset binary, mid-code 128 = VCM.
// The 16-point cosine and the amplitude select both live in the digital, so
// by the time a code reaches this pin it already carries the chosen
// excursion. This block is a pure code-to-voltage map with no control of its
// own.
// -----------------------------------------------------------------------------
module afe_beh_sine_dac
  import agriasic_afe_pkg::*;
#(
  parameter int unsigned CODE_W       = 8,
  parameter real         VCM_V        = VCM_NOM_V,
  parameter real         HALF_SWING_V = E1_HALF_SWING_V,  // GAP-A5: placeholder
  parameter real         SETTLE_NS    = 2.0               // buffer step response
) (
  input  logic              enable_i,
  input  logic [CODE_W-1:0] code_i,
  output real               e1_drive_o
);

  localparam real MidCode = 128.0;

  real v_target;
  real v_now;

  // The code-to-voltage map is evaluated HERE, inside the stepped process,
  // rather than in an always_comb. A real expression that is a pure function
  // of a narrow logic vector gets folded into a lookup table over the whole
  // input domain, and that table is emitted with an integer type: 256 codes
  // in, 256 narrowing-conversion errors out. Evaluating it procedurally
  // leaves nothing to fold. Same reason the gain select below is an if/else
  // chain rather than a case.
  initial begin
    v_target = VCM_V;
    v_now    = VCM_V;
  end

  always begin
    #(ANALOG_STEP_NS);
    v_target = enable_i
             ? VCM_V + ((real'(code_i) - MidCode) / MidCode) * HALF_SWING_V
             : VCM_V;
    v_now = v_now + (1.0 - $exp(-ANALOG_STEP_NS / SETTLE_NS)) * (v_target - v_now);
  end

  assign e1_drive_o = v_now;

endmodule

// -----------------------------------------------------------------------------
// Differential voltage-sense amplifier on electrodes E2/E3.
//
// Gain is FIXED -- docs/interface_contract.md: "The differential PGA has a
// FIXED gain and no digital control", AFE_CTRL[1:0] reads 0.
//
// The 266.9 MHz pole is NOT modelled as a pole. The excitation is in the kHz
// decade, so the amplifier sits four to five decades inside its band and a
// one-pole model would contribute nothing but numerical error at the package
// timestep (tau = 0.6 ns against a 0.5 ns step). BW_HZ is carried as a
// parameter so the figure stays attached to the block.
// -----------------------------------------------------------------------------
module afe_beh_pga
  import agriasic_afe_pkg::*;
#(
  parameter real GAIN_DB = PGA_GAIN_DB,   // 4.1 dB, voltage-sense slide
  parameter real BW_HZ   = PGA_BW_HZ,     // 266.9 MHz, documentation only
  parameter real VCM_V   = VCM_NOM_V,
  parameter real VSAT_LO = VSSA_NOM_V + 0.10,
  parameter real VSAT_HI = VDDA_NOM_V - 0.10
) (
  input  real vin_p_i,
  input  real vin_n_i,
  output real vout_o
);

  localparam real GainLin   = 10.0 ** (GAIN_DB / 20.0);
  localparam real UnusedBw  = BW_HZ;

  real v_ideal;
  assign v_ideal = VCM_V + (vin_p_i - vin_n_i) * GainLin;

  // The output stage clips at the rails. Without this a bench that drives an
  // over-range differential input gets a plausible-looking code back instead
  // of the saturation the silicon would show.
  assign vout_o = (v_ideal > VSAT_HI) ? VSAT_HI
                : (v_ideal < VSAT_LO) ? VSAT_LO
                : v_ideal;

endmodule

// -----------------------------------------------------------------------------
// Return-current transimpedance amplifier on electrode E4, with its switched
// feedback network.
//
// Contract pin: afe_tia_rf_o[2:0] -- THREE SWITCH WIRES, already decoded.
// agriasic_rv32i_mmio's gain_decode turns the 2-bit AFE_CTRL code into these
// wires, so this block does no decoding: it reads the wires directly and the
// illegal combinations are unreachable by construction.
//
//   wires 001 -> 67.02 dB (2.245 kohm), 197.1 MHz    [a1, current-sense slide]
//   wires 010 -> 74.27 dB (5.168 kohm),  99.8 MHz    [a2]
//   wires 100 -> 89.00 dB (28.18 kohm),  18.6 MHz    [a3]
//   wires 111 -> GAP-A4, all three in parallel, never simulated
// -----------------------------------------------------------------------------
module afe_beh_tia
  import agriasic_afe_pkg::*;
#(
  parameter real VCM_V     = VCM_NOM_V,
  parameter bit  INVERTING = 1'b1,
  parameter real VSAT_LO   = VSSA_NOM_V + 0.10,
  parameter real VSAT_HI   = VDDA_NOM_V - 0.10
) (
  input  logic [2:0] rf_sel_i,     // afe_tia_rf_o, one wire per switch
  input  real        iin_i,        // amperes into E4
  output real        vout_o,
  output real        rf_ohm_o      // diagnostic: selected transimpedance
);

  real rf_ohm;
  real v_ideal;

  // if/else rather than a case: Verilator 5.020 lowers a case that selects
  // between REAL CONSTANTS into an integer constant pool and the build fails
  // with a narrowing-conversion error. Do not "simplify" this back to a case.
  always_comb begin
    if      (rf_sel_i == 3'b001) rf_ohm = 10.0 ** (TIA_GAIN_DB_A1 / 20.0);
    else if (rf_sel_i == 3'b010) rf_ohm = 10.0 ** (TIA_GAIN_DB_A2 / 20.0);
    else if (rf_sel_i == 3'b100) rf_ohm = 10.0 ** (TIA_GAIN_DB_A3 / 20.0);
    else if (rf_sel_i == 3'b111) rf_ohm = TIA_GAIN_OHM_PAR;      // GAP-A4
    else                         rf_ohm = 10.0 ** (TIA_GAIN_DB_A1 / 20.0);
  end

  // An all-open feedback network has no DC path and the output rails. The
  // digital is built so this cannot happen -- gain_decode never emits 000 --
  // and this check is here in case that ever changes.
  always @(rf_sel_i) begin
    if (rf_sel_i == 3'b000)
      $warning("%m: TIA feedback network fully open (rf_sel = 000); output would rail");
  end

  assign v_ideal = INVERTING ? (VCM_V - iin_i * rf_ohm)
                             : (VCM_V + iin_i * rf_ohm);

  assign vout_o   = (v_ideal > VSAT_HI) ? VSAT_HI
                  : (v_ideal < VSAT_LO) ? VSAT_LO
                  : v_ideal;
  assign rf_ohm_o = rf_ohm;

endmodule

// -----------------------------------------------------------------------------
// One isolated sample-and-hold channel. Two are instantiated, for dV and for
// return current, and both are strobed together.
//
// GAP-A6 -- THE REASON THIS BLOCK IS PARAMETERISED TWICE OVER.
// afe_sample_o is a ONE-CLOCK pulse: sar_controller.sv defaults it low every
// cycle and sets it only on request acceptance, so at 160 MHz it is 6.25 ns
// wide. Nothing in the repo says how the analog wires that pulse to the hold
// switch, and the two readings differ by about 8x in acquisition time:
//
//   STROBE_MODE = "TRACK_WHILE_HIGH"
//       The pulse IS the acquisition window: the switch closes for 6.25 ns.
//       The sampling slide needs roughly 40-50 ns to settle below half an LSB
//       from a 10 ohm source, so this reading is short by about 8x and the
//       held value lands tens of LSBs away from the input.
//
//   STROBE_MODE = "FREEZE_ON_RISE"   (default)
//       The switch is closed by default and the pulse commands a freeze. The
//       channel has acquired over the whole preceding interval, so 6.25 ns
//       only has to exceed the switch turn-off time and the sample is good.
//       This matches the RTL's own wording ("freezes BOTH channels at this
//       instant"), which is why it is the default here.
//
// The second reading carries a consequence of its own: there is NO RELEASE
// SIGNAL on the digital boundary. Nothing marks "both conversions done", so
// the analog has to self-time the hold with a fixed timer that must outlast
// the longest conversion pair. HOLD_NS models that timer, and the top checks
// whether it ever expires mid-conversion.
//
// acq_err_v_o is the deliverable: held value minus the input at the instant
// of freeze. Divide by ADC_LSB_V to read it in LSBs.
// -----------------------------------------------------------------------------
module afe_beh_sample_hold
  import agriasic_afe_pkg::*;
#(
  parameter real   TAU_NS         = SH_TAU_NS,        // GAP-A2, read off a plot
  parameter real   APERTURE_NS    = 0.05,             // switch turn-off delay
  parameter real   DROOP_V_PER_US = 0.0,              // leakage; 0 = ideal
  parameter string STROBE_MODE    = "FREEZE_ON_RISE", // see GAP-A6 above
  parameter real   HOLD_NS        = 460.0,            // GAP-A6: see below
  parameter real   VINIT_V        = VCM_NOM_V
) (
  input  logic strobe_i,
  input  real  vin_i,
  output real  vout_o,
  output logic holding_o,     // diagnostic: 1 while the switch is open
  output real  acq_err_v_o    // diagnostic: acquisition error at freeze
);
  // HOLD_NS = 460 ns sits inside a window the chip-top bench MEASURED, and
  // that window is the finding: the hold must exceed the conversion pair
  // (450 ns) and stay under the strobe interval (475 ns). 25 ns of room,
  // about +/-2.7%, and the firmware can move both ends through mux_settle
  // and conv_cycles. No fixed analog timer holds that across corners, so
  // self-timing is not a viable answer to GAP-A6 -- the boundary needs an
  // explicit release signal. See docs/analog_integration_gaps.md.

  localparam bit TrackHigh = (STROBE_MODE == "TRACK_WHILE_HIGH");

  real  v_hold;
  logic tracking;
  real  acq_err;

  initial begin
    v_hold   = VINIT_V;
    acq_err  = 0.0;
    // TRACK_WHILE_HIGH starts open (nothing acquired yet); FREEZE_ON_RISE
    // starts closed, which is the whole point of that reading.
    tracking = TrackHigh ? 1'b0 : 1'b1;
  end

  // Continuous-time RC acquisition. The AFE boundary carries no clock, so
  // this advances on the package timestep rather than on an edge.
  always begin
    #(ANALOG_STEP_NS);
    if (tracking) begin
      v_hold = v_hold + (1.0 - $exp(-ANALOG_STEP_NS / TAU_NS)) * (vin_i - v_hold);
    end else if (DROOP_V_PER_US != 0.0) begin
      v_hold = v_hold - DROOP_V_PER_US * (ANALOG_STEP_NS / 1000.0);
    end
  end

  if (TrackHigh) begin : gen_track_high
    always @(posedge strobe_i) begin
      tracking = 1'b1;
    end
    always @(negedge strobe_i) begin
      #(APERTURE_NS);
      acq_err  = v_hold - vin_i;
      tracking = 1'b0;
    end
  end else begin : gen_freeze_on_rise
    // The freeze and the self-timed release are driven from a TIMESTAMP
    // evaluated in a stepped process, not from delays inside the edge-
    // sensitive block. An always block suspended in a # delay does not
    // restart on a new edge, so writing it that way silently SWALLOWS every
    // strobe that arrives during a hold -- which, with strobes about 750 ns
    // apart and a hold longer than that, means every sample after the first.
    // Same reason the comparator's retriggerable one-shot is written this
    // way.
    realtime t_freeze;
    logic    freeze_pending;

    initial begin
      t_freeze       = -1.0;
      freeze_pending = 1'b0;
    end

    always @(posedge strobe_i) begin
      if (!tracking)
        $warning("%m GAP-A6: strobe while holding; HOLD_NS=%0.1f exceeds the strobe interval",
                 HOLD_NS);
      t_freeze       = $realtime;
      freeze_pending = 1'b1;
    end

    // freeze_pending is what makes a freeze happen ONCE per strobe. Without
    // it, the step after the hold releases finds the aperture condition
    // still true and re-freezes immediately, and the model oscillates at
    // twice the timestep instead of sampling.
    always begin
      #(ANALOG_STEP_NS);
      if (freeze_pending && tracking
          && ($realtime - t_freeze) >= APERTURE_NS) begin
        acq_err        = v_hold - vin_i;
        tracking       = 1'b0;
        freeze_pending = 1'b0;
      end else if (!tracking && HOLD_NS > 0.0
                   && ($realtime - t_freeze) >= HOLD_NS) begin
        tracking = 1'b1;
      end
    end
  end

  assign vout_o      = v_hold;
  assign holding_o   = ~tracking;
  assign acq_err_v_o = acq_err;

endmodule

// -----------------------------------------------------------------------------
// Analog input multiplexer ahead of the converter.
//
// Contract pin: afe_mux_sel_o[1:0] -- 0 = dV (PGA on E2/E3), 1 = return
// current (TIA on E4), "stable for the whole conversion".
//
// GAP-A7. The pin is two bits wide but the contract defines only codes 0 and
// 1. The subsystem slide shows a temperature divider at VIN_T with no route
// to the converter, which is the obvious candidate for code 2 -- but that is
// an inference, not a specification, so this model drives VCM and warns
// rather than inventing the channel.
// -----------------------------------------------------------------------------
module afe_beh_mux
  import agriasic_afe_pkg::*;
#(
  parameter real VCM_V = VCM_NOM_V
) (
  input  logic [1:0] sel_i,
  input  real        in_dv_i,
  input  real        in_cur_i,
  output real        vout_o
);

  real v_sel;

  // See the note in afe_beh_tia: a case selecting reals does not survive
  // constant pooling in the simulator. (A comment line must not START with
  // the simulator's name either -- that parses as a lint directive.)
  always_comb begin
    if      (sel_i == 2'd0) v_sel = in_dv_i;
    else if (sel_i == 2'd1) v_sel = in_cur_i;
    else                    v_sel = VCM_V;       // GAP-A7
  end

  always @(sel_i) begin
    if (sel_i > 2'd1)
      $warning("%m: afe_mux_sel = %0d is undefined in the interface contract (GAP-A7)",
               sel_i);
  end

  assign vout_o = v_sel;

endmodule

// -----------------------------------------------------------------------------
// 8-bit differential charge-redistribution DAC and dynamic comparator -- the
// cdac_diff_8b + dynamic_comparator pair from the ADC schematic.
//
// The SAR bit trials stay in DIGITAL (confirmed with the ADC owner,
// docs/interface_contract.md). The boundary is one trial code out and one
// decision back, so this block holds no successive-approximation logic.
//
// GAP-A3 -- the schematic's CLK_COMP, RESET and DAC_EN pins have no
// counterpart on the digital boundary, which carries only afe_adc_dac_o,
// afe_conv_start_o and afe_adc_enable_o. Something has to generate them
// inside the macro, and the contract already flags the related open item:
// the ADC report's Q7 measures settling from REFERENCE-SWITCH ENABLE, while
// the digital can only offer the code edge. This model therefore times
// settling from the code edge, which is the OPTIMISTIC case -- if the real
// block needs an explicit per-trial enable, the true settling window is
// shorter than modelled here and REG_CONV is undersized by the difference.
//
// comp_valid_o is the deliverable: it marks when the decision is actually
// trustworthy, so a bench can assert the digital never sampled before it.
// -----------------------------------------------------------------------------
module afe_beh_cdac_comp
  import agriasic_afe_pkg::*;
#(
  parameter int unsigned CODE_W    = ADC_BITS,
  parameter real         VREFH_V   = VREFH_NOM_V,
  parameter real         VREFL_V   = VREFL_NOM_V,
  parameter real         SETTLE_NS = CDAC_SETTLE_NS,   // GAP-A3
  parameter real         REGEN_NS  = COMP_REGEN_NS,    // GAP-A3
  parameter real         OFFSET_V  = COMP_OFFSET_V,
  // What the comparator presents while it is still regenerating.
  //   "HOLD"   keeps the previous decision -- benign, and the default so the
  //            existing regression's timing expectations are unchanged.
  //   "INVERT" presents the WRONG answer, which makes an undersized REG_CONV
  //            fail loudly instead of passing by luck.
  parameter string       INVALID_POLICY = "HOLD"
) (
  input  logic              enable_i,      // afe_adc_enable_o
  input  logic              conv_start_i,  // afe_conv_start_o
  input  logic [CODE_W-1:0] dac_code_i,    // afe_adc_dac_o
  input  real               vin_i,         // held sample via the analog mux
  output logic              comp_o,        // afe_adc_comp_i
  output logic              comp_valid_o,  // diagnostic
  output real               vtrial_o       // diagnostic
);

  localparam bit  DoInvert = (INVALID_POLICY == "INVERT");
  localparam real FsV      = VREFH_V - VREFL_V;
  localparam real ValidNs  = SETTLE_NS + REGEN_NS;

  // Trial voltage for the code currently presented, and the ideal decision
  // before any timing is applied. Polarity follows the contract: 1 = input
  // >= trial code. Both are computed in the stepped process below for the
  // same reason as the sine DAC's map -- see the note in afe_beh_sine_dac.
  real  v_trial;
  logic decision;

  // Retrigger on a code edge or on conv_start. $realtime rather than a timer
  // process: an always block suspended in a # delay does not restart on a new
  // event, so a retriggerable one-shot cannot be written that way.
  realtime t_retrigger;
  initial  t_retrigger = 0.0;
  always @(dac_code_i or posedge conv_start_i) t_retrigger = $realtime;

  logic valid_q;
  logic comp_q;

  initial begin
    valid_q  = 1'b0;
    comp_q   = 1'b0;
    v_trial  = VREFL_V;
    decision = 1'b0;
  end

  always begin
    #(ANALOG_STEP_NS);
    v_trial  = VREFL_V + (real'(dac_code_i) / ADC_CODES) * FsV;
    decision = ((vin_i + OFFSET_V) >= v_trial);
    valid_q  = enable_i && (($realtime - t_retrigger) >= ValidNs);
    if (!enable_i) begin
      // Comparator bias is gated off between conversions; the output is not
      // meaningful and the digital is not reading it.
      comp_q = 1'b0;
    end else if (valid_q) begin
      comp_q = decision;
    end else if (DoInvert) begin
      comp_q = ~decision;
    end
    // INVALID_POLICY == "HOLD": comp_q keeps its previous value.
  end

  assign comp_o       = comp_q;
  assign comp_valid_o = valid_q;
  assign vtrial_o     = v_trial;

endmodule

// -----------------------------------------------------------------------------
// Bias distribution, modelled as a check rather than as a circuit.
//
// The subsystem slide quotes IBIAS = 4.6 uA and IBIAS_ADC = 60 uA total. The
// behavioural blocks do not consume a bias current, so modelling the mirror
// network would buy nothing. What IS worth modelling is the failure this
// wrapper can actually catch: a top-level bench that forgets to drive the
// bias pin, or drives it out of range, and then reports plausible-looking
// conversion results anyway.
// -----------------------------------------------------------------------------
module afe_beh_bias
  import agriasic_afe_pkg::*;
#(
  parameter real IBIAS_NOM = IBIAS_NOM_A,
  parameter real TOL       = IBIAS_TOL
) (
  input  real  ibias_i,
  output logic bias_ok_o
);

  localparam real ILo = IBIAS_NOM * (1.0 - TOL);
  localparam real IHi = IBIAS_NOM * (1.0 + TOL);

  assign bias_ok_o = (ibias_i >= ILo) && (ibias_i <= IHi);

  always @(ibias_i) begin
    if (!bias_ok_o)
      $warning("%m: AFE bias %0.3f uA outside %0.3f-%0.3f uA; analog results are not meaningful",
               ibias_i * 1.0e6, ILo * 1.0e6, IHi * 1.0e6);
  end

endmodule

// =============================================================================
// THE MACRO. This port list is the specification the analog top must meet.
// =============================================================================
module agriasic_afe_top
  import agriasic_afe_pkg::*;
#(
  parameter int unsigned ADC_WIDTH = ADC_BITS,
  // GAP-A6. Which reading of the one-clock afe_sample_o pulse to model. The
  // two differ by about 8x in acquisition time and nothing in the repo
  // settles which is right.
  parameter string       SH_STROBE_MODE      = "FREEZE_ON_RISE",
  parameter real         SH_HOLD_NS          = 460.0,
  // GAP-A3. "INVERT" makes an undersized REG_CONV fail loudly.
  parameter string       COMP_INVALID_POLICY = "HOLD",
  parameter bit          QUIET               = 1'b0
) (
  // ---- Digital boundary: the interface contract, verbatim -------------------
  input  logic [ADC_WIDTH-1:0] afe_sine_code_i,
  input  logic [1:0]           afe_mux_sel_i,
  input  logic                 afe_sample_i,
  input  logic                 afe_adc_enable_i,
  input  logic [ADC_WIDTH-1:0] afe_adc_dac_i,
  output logic                 afe_adc_comp_o,
  input  logic                 afe_conv_start_i,
  input  logic [2:0]           afe_tia_rf_i,

  // ---- Analog boundary: electrodes ------------------------------------------
  output real                  e1_drive_o,    // excitation drive out
  input  real                  e2_sense_i,    // dV sense +
  input  real                  e3_sense_i,    // dV sense -
  input  real                  e4_iin_i,      // return current in, amperes
  input  real                  vin_t_i,       // temperature divider tap

  // ---- Analog boundary: supplies and references -----------------------------
  // GAP-A1. Whether VREFH/VREFL/VCM are pads or come from an on-die bandgap
  // is not recorded anywhere. They are inputs here so a bench cannot run
  // without stating them, which is the safer default of the two.
  input  real                  vdda_i,
  input  real                  vssa_i,
  input  real                  vrefh_i,
  input  real                  vrefl_i,
  input  real                  vcm_i,
  input  real                  ibias_i
);

  // ---------------------------------------------------------------------------
  // Signal chain
  // ---------------------------------------------------------------------------
  real  pga_out, tia_out, tia_rf_ohm;
  real  sh_dv_out, sh_cur_out, mux_out;
  real  acq_err_dv, acq_err_cur, v_trial;
  logic sh_dv_holding, sh_cur_holding;
  logic comp_valid, bias_ok;

  // Excitation. There is no excitation-enable pin on the boundary: the
  // digital parks afe_sine_code_o at mid-code when idle, so the DAC is
  // unconditionally enabled here.
  afe_beh_sine_dac #(
    .CODE_W (ADC_WIDTH)
  ) u_sine_dac (
    .enable_i   (1'b1),
    .code_i     (afe_sine_code_i),
    .e1_drive_o (e1_drive_o)
  );

  // Voltage sense: fixed-gain differential amplifier on E2/E3.
  afe_beh_pga u_pga (
    .vin_p_i (e2_sense_i),
    .vin_n_i (e3_sense_i),
    .vout_o  (pga_out)
  );

  // Current sense: switched-gain transimpedance amplifier on E4.
  afe_beh_tia u_tia (
    .rf_sel_i (afe_tia_rf_i),
    .iin_i    (e4_iin_i),
    .vout_o   (tia_out),
    .rf_ohm_o (tia_rf_ohm)
  );

  // Two matched sample-and-holds, strobed by the SAME signal. The contract
  // calls this out explicitly ("freezes BOTH channels simultaneously") and
  // the ADC progress report of 2026-10-26 confirms the two schematics share
  // sampling phases, so this is a modelled fact, not an assumption.
  afe_beh_sample_hold #(
    .STROBE_MODE (SH_STROBE_MODE),
    .HOLD_NS     (SH_HOLD_NS)
  ) u_sh_dv (
    .strobe_i    (afe_sample_i),
    .vin_i       (pga_out),
    .vout_o      (sh_dv_out),
    .holding_o   (sh_dv_holding),
    .acq_err_v_o (acq_err_dv)
  );

  afe_beh_sample_hold #(
    .STROBE_MODE (SH_STROBE_MODE),
    .HOLD_NS     (SH_HOLD_NS)
  ) u_sh_cur (
    .strobe_i    (afe_sample_i),
    .vin_i       (tia_out),
    .vout_o      (sh_cur_out),
    .holding_o   (sh_cur_holding),
    .acq_err_v_o (acq_err_cur)
  );

  // Channel select, AFTER the holds: both channels are frozen at one instant
  // and the mux then presents them to the converter one at a time.
  afe_beh_mux u_mux (
    .sel_i    (afe_mux_sel_i),
    .in_dv_i  (sh_dv_out),
    .in_cur_i (sh_cur_out),
    .vout_o   (mux_out)
  );

  afe_beh_cdac_comp #(
    .CODE_W         (ADC_WIDTH),
    .INVALID_POLICY (COMP_INVALID_POLICY)
  ) u_cdac (
    .enable_i     (afe_adc_enable_i),
    .conv_start_i (afe_conv_start_i),
    .dac_code_i   (afe_adc_dac_i),
    .vin_i        (mux_out),
    .comp_o       (afe_adc_comp_o),
    .comp_valid_o (comp_valid),
    .vtrial_o     (v_trial)
  );

  afe_beh_bias u_bias (
    .ibias_i   (ibias_i),
    .bias_ok_o (bias_ok)
  );

  // ---------------------------------------------------------------------------
  // Integration checks. Each corresponds to a numbered gap in
  // docs/analog_integration_gaps.md.
  // ---------------------------------------------------------------------------

  // GAP-A6: the hold has no release signal, so the analog self-times it. If
  // that timer expires while a conversion is still running, the converter is
  // digitising a re-acquiring node and the result is silently wrong.
  always @(negedge sh_dv_holding) begin
    if (afe_adc_enable_i && !QUIET)
      $error("%m GAP-A6: dV S/H released mid-conversion; SH_HOLD_NS=%0.1f too short",
             SH_HOLD_NS);
  end
  always @(negedge sh_cur_holding) begin
    if (afe_adc_enable_i && !QUIET)
      $error("%m GAP-A6: I S/H released mid-conversion; SH_HOLD_NS=%0.1f too short",
             SH_HOLD_NS);
  end

  // The contract requires afe_mux_sel_o to be "stable for the whole
  // conversion". Nothing enforces it on the digital side.
  //
  // Compared against enable as it was BEFORE this instant, not as it is now:
  // sar_controller assigns mux_sel_o and adc_enable_o on the SAME clock edge
  // when it accepts a conversion, so testing the live value reports every
  // legal conversion start as a violation.
  logic enable_d;
  initial enable_d = 1'b0;
  always begin
    #(ANALOG_STEP_NS);
    enable_d = afe_adc_enable_i;
  end

  always @(afe_mux_sel_i) begin
    if (enable_d && afe_adc_enable_i && !QUIET)
      $error("%m: afe_mux_sel changed mid-conversion; the contract requires it stable");
  end

  // Acquisition error at each freeze, reported in LSBs. This is the number
  // GAP-A6 turns on: under TRACK_WHILE_HIGH it is tens of LSBs, under
  // FREEZE_ON_RISE a fraction of one.
  always @(posedge sh_dv_holding) begin
    if (!QUIET)
      $display("[%0t] %m acquisition error: dV %0.2f LSB, I %0.2f LSB",
               $realtime, acq_err_dv / ADC_LSB_V, acq_err_cur / ADC_LSB_V);
  end

  initial begin
    if (!QUIET) begin
      $display("-------------------------------------------------------------");
      $display(" agriasic_afe_top: BEHAVIOURAL MODEL -- not the silicon.");
      $display("   S/H strobe reading : %s   (GAP-A6)", SH_STROBE_MODE);
      $display("   comparator policy  : %s   (GAP-A3)", COMP_INVALID_POLICY);
      $display("   LSB                : %0.3f mV", ADC_LSB_V * 1000.0);
      $display("-------------------------------------------------------------");
    end
  end

  // vin_t_i has no route to the converter: the temperature divider appears on
  // the subsystem schematic but the mux contract defines only codes 0 and 1.
  // See GAP-A7. The supplies and the diagnostics are gathered here so no port
  // or internal is reported dead while still being available in waveforms.
  real unused_sink;
  assign unused_sink = vin_t_i + vdda_i + vssa_i + vrefh_i + vrefl_i + vcm_i
                     + tia_rf_ohm + v_trial
                     + real'(comp_valid) + real'(bias_ok);

endmodule
