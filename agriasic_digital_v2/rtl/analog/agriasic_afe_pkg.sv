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

  // GAP-A1. The SAR reference pair is not written down anywhere in the repo.
  // These values are BACK-DERIVED, not measured: the sampling slide quotes a
  // half-LSB of 1.953 mV, so LSB = 3.906 mV and an 8-bit full scale is
  // 1.000 V. Centring that on VCM gives 0.4 V / 1.4 V. Confirm against the
  // CDAC schematic's VREFH/VREFL before trusting any absolute voltage here.
  parameter real VREFH_NOM_V = 1.40;
  parameter real VREFL_NOM_V = 0.40;

  // ---- Converter scale ------------------------------------------------------
  parameter int unsigned ADC_BITS  = 8;
  parameter real         ADC_FS_V  = VREFH_NOM_V - VREFL_NOM_V;   // 1.000 V
  parameter real         ADC_CODES = 256.0;                       // 2 ** ADC_BITS
  parameter real         ADC_LSB_V = ADC_FS_V / ADC_CODES;        // 3.906 mV

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
  parameter real TIA_GAIN_DB_A1 = 67.02;   // -> 2.245 kohm
  parameter real TIA_GAIN_DB_A2 = 74.27;   // -> 5.168 kohm
  parameter real TIA_GAIN_DB_A3 = 89.00;   // -> 28.18 kohm
  parameter real TIA_BW_HZ_A1   = 197.1e6;
  parameter real TIA_BW_HZ_A2   = 99.8e6;
  parameter real TIA_BW_HZ_A3   = 18.6e6;

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
  // GAP-A3. Per-trial settling. The ADC progress report's Q7 measures
  // settling from reference-switch enable, and no such enable exists on the
  // digital boundary, so this models settling from the code edge instead --
  // which is the optimistic case. Both numbers are placeholders.
  parameter real CDAC_SETTLE_NS = 3.0;
  parameter real COMP_REGEN_NS  = 1.5;

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
