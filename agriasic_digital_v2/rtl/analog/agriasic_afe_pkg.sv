// -----------------------------------------------------------------------------
// Package: agriasic_afe_pkg
// Purpose:
//   Shared electrical constants for the AgriASIC analog front-end behavioural
//   models. SIMULATION ONLY -- nothing in rtl/analog/ is ever read by
//   synthesis; see rtl/analog/README.md.
//
// Provenance of every number below is stated inline. Where a value is a
// placeholder rather than a measurement it carries a GAP-A<n> tag that is
// written up in docs/analog_integration_gaps.md. Replace placeholders from
// the analog team's characterisation, not by guessing.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

package agriasic_afe_pkg;

  // ---- Supplies and references ---------------------------------------------
  // VDDA / VCM: docs/interface_contract.md, "mid-code 128 = VCM (0.9 V)".
  parameter real VDDA_NOM_V = 1.80;
  parameter real VSSA_NOM_V = 0.00;
  parameter real VCM_NOM_V  = 0.90;

  // GAP-A1 CLOSED (2026-11-19). These were back-derived from the sampling
  // slide's 1.953 mV half-LSB; the analog side has since confirmed the
  // converter range directly as 0.4 V to 1.4 V, so the derivation was right
  // and every absolute voltage below rests on a confirmed number.
  parameter real VREFH_NOM_V = 1.40;
  parameter real VREFL_NOM_V = 0.40;

  // The FAST sampling path is targeted at a narrower window than the full
  // converter range (2026-11-19). Outside it a conversion still returns a
  // code, but that code is not trustworthy at speed -- which the digital
  // cannot currently tell, because sar_controller flags overrange only at
  // code 0 and code 255. See GAP-A9.
  parameter real ADC_FAST_VLO_V = 0.50;
  parameter real ADC_FAST_VHI_V = 1.30;

  // ---- Converter scale ------------------------------------------------------
  parameter int unsigned ADC_BITS  = 8;
  parameter real         ADC_FS_V  = VREFH_NOM_V - VREFL_NOM_V;   // 1.000 V
  parameter real         ADC_CODES = 256.0;                       // 2 ** ADC_BITS
  parameter real         ADC_LSB_V = ADC_FS_V / ADC_CODES;        // 3.906 mV

  // The fast-path window above, in codes: 26 .. 230 of 0 .. 255.
  parameter int unsigned ADC_FAST_CODE_LO = 26;
  parameter int unsigned ADC_FAST_CODE_HI = 230;

  // ---- Bias -----------------------------------------------------------------
  // Sampling + SAR ADC subsystem slide: "IBIAS=4.6uA, IBIAS_ADC=60uA total".
  parameter real IBIAS_NOM_A     = 4.6e-6;
  parameter real IBIAS_ADC_NOM_A = 60.0e-6;
  parameter real IBIAS_TOL       = 0.20;   // +/-20% before the models complain

  // ---- Sample and hold ------------------------------------------------------
  // Hold-node capacitance from the subsystem slide: 2.0396 pF.
  parameter real SH_CHOLD_F = 2.0396e-12;
  // GAP-A2. Acquisition time constant. The sampling slide shows the storage
  // capacitor settling below half an LSB roughly 40-50 ns after the input
  // ramp for a 10 ohm source, which implies tau ~= 7 ns (settling to half an
  // LSB of full scale takes ln(512) ~= 6.24 tau). Back-annotate from
  // extraction; this is read off a plot.
  parameter real SH_TAU_NS = 7.2;

  // ---- Voltage sense path (differential PGA) --------------------------------
  // Voltage Sense Simulations slide: 4.1 dB, 266.9 MHz.
  parameter real PGA_GAIN_DB = 4.1;
  parameter real PGA_BW_HZ   = 266.9e6;

  // ---- Current sense path (TIA) ---------------------------------------------
  // Current Sense Simulations slide. The legend maps the one-hot switch wires
  // to the three traces: a1 (1.8 0.0 0.0) = 67.02 dB, a2 (0.0 1.8 0.0) =
  // 74.27 dB, a3 (0.0 0.0 1.8) = 89.0 dB. Transimpedance in ohms is
  // 10 ** (dB / 20).
  //
  // IN FLUX (2026-11-20). The analog side is restructuring this stage:
  // lowering the feedback resistors and adding a fixed-gain amplifier after
  // the PGA, to fix a DC-headroom problem at high gain (GAP-A10) while
  // holding total transimpedance. Treat the gains below as the LAST
  // CHARACTERISED set, not the final one, and do not propagate them into
  // off-die calibration. What the digital will need when it settles is the
  // END-TO-END current-path gain and phase versus frequency per setting --
  // a second stage adds a second pole, and the de-embedding works on the
  // composite against the voltage channel, not on either stage alone.
  parameter real TIA_GAIN_DB_A1 = 67.02;   // -> 2.245 kohm
  parameter real TIA_GAIN_DB_A2 = 74.27;   // -> 5.168 kohm
  parameter real TIA_GAIN_DB_A3 = 89.00;   // -> 28.18 kohm
  parameter real TIA_BW_HZ_A1   = 197.1e6;
  parameter real TIA_BW_HZ_A2   = 99.8e6;
  // a3 was re-tuned from 18.6 MHz to 13 MHz (2026-11-18) to cut noise; see
  // TIA_INOISE_A below. This is the setting the 400 nA figure belongs to.
  parameter real TIA_BW_HZ_A3   = 13.0e6;

  // Input-referred noise current at the high-gain / 13 MHz setting, measured
  // 2026-11-18. At 28.18 kohm that is 11.3 mV at the converter, about 2.9
  // LSB, so analog noise still sits above the quantisation floor and digital
  // averaging still pays: REG_PAIR_LOG2 = 6 (64 pairs, the clamp in
  // measurement_fsm.sv) is worth 4x and takes it to roughly 0.7 LSB.
  // Firmware currently sets 2.
  parameter real TIA_INOISE_A = 400.0e-9;

  // The 13 MHz pole is NOT negligible against the sweep. Phase lag is
  // atan(f / 13 MHz) on the current channel while the voltage channel sits
  // at 266.9 MHz, and only the DIFFERENCE lands in Z = dV / I:
  //   10 MHz   -> 35.5 deg net, |Z| reads about 26 % high
  //    1 MHz   ->  4.2 deg
  //  312 kHz   ->  1.3 deg
  //  <=100 kHz -> under 0.5 deg
  // This is de-embedded off die, not corrected in RTL. The two fast sweep
  // points are the ones that need it.

  // GAP-A4. agriasic_rv32i_mmio's gain_decode emits 3'b111 for AFE_CTRL code
  // 3 (all three switches in parallel), but the current-sense slide only
  // simulated the three one-hot settings. This is the parallel combination of
  // the three transimpedances above -- ARITHMETIC, not a simulation result.
  parameter real TIA_GAIN_OHM_PAR = 1483.0;
  parameter real TIA_BW_HZ_PAR    = 197.1e6;  // placeholder: widest of the three

  // ---- Excitation drive ------------------------------------------------------
  // GAP-A5. The E1 drive excursion is not specified anywhere. afe_sine_code_o
  // is documented as offset binary with mid-code 128 = VCM, which fixes the
  // centre but not the span. 0.45 V half-swing keeps the drive inside the
  // rails with margin; it is a PLACEHOLDER.
  parameter real E1_HALF_SWING_V = 0.45;

  // ---- Converter timing ------------------------------------------------------
  // GAP-A3 CLOSED for the interface, PROVISIONAL for the numbers
  // (2026-11-19). The macro now takes afe_adc_dac_o as the trial code and
  // returns one comparator decision, generating its switching controls
  // internally with no second SAR search and no code-out pin -- which is the
  // contract. (An earlier macro version DID run its own successive
  // approximation; confirm the new one is what goes to layout.)
  //
  // Both numbers below are referenced to OUR CODE EDGE, which is the only
  // reference the digital boundary has:
  //   - enable arrived 6.25 ns after the code edge, and DAC settling was
  //     measured 3.125 ns after enable -> 9.375 ns from the edge
  //   - comparator: 0.96 ns, worst of five corners at +/-1 mV input
  // Total 10.3 ns. sar_controller waits S_TRIAL_SET + (conv_cycles+1), so
  // 3 cycles = 18.75 ns at REG_CONV = 1 -- adequate, with 8.4 ns of margin.
  // REG_CONV = 0 would give 12.5 ns and only 2.2 ns of margin: too tight.
  //
  // PROVISIONAL because the 6.25 ns enable offset was measured on the OLD
  // sequencer. The new interface's offset is still being characterised.
  parameter real CDAC_SETTLE_NS = 9.375;
  parameter real COMP_REGEN_NS  = 0.96;

  // Input-referred comparator offset. The ADC simulation slide reports
  // 7.42-bit ENOB (voltage) and 7.52-bit (current) against 8 bits nominal;
  // 0 V here models the ideal converter, so raise it to explore that loss.
  parameter real COMP_OFFSET_V = 0.0;

  // ---- Model stepping --------------------------------------------------------
  // The AFE boundary carries no clock, so the continuous-time blocks advance
  // on their own timestep. 0.5 ns resolves the 6.25 ns sample strobe into
  // about a dozen points, which is what GAP-A6 needs to be measurable.
  parameter real ANALOG_STEP_NS = 0.5;

endpackage
