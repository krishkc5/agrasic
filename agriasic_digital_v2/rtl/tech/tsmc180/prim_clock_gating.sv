// -----------------------------------------------------------------------------
// Module: prim_clock_gating  (TSMC 180 nm, tcb018gbwp7t -- ASIC build only)
//
// Drop-in replacement for ibex/prim_generic/prim_clock_gating.sv: same module
// name, parameters and ports, so EXACTLY ONE of the two may be in a file list.
//
//   synthesis / LEC / STA   this file   (digital-flow design/agrasic.f)
//   simulation              prim_generic (rtl/ibex/ibex.f, Verilator runs)
//
// Never add this file to a simulation list: Verilator has no model for the
// library cell, and both files define the same module.
//
// Why a library cell instead of the generic model:
//   prim_generic is a latch transparent while clk is low followed by an AND.
//   Synthesis builds that from a separate latch and a separate NAND/AND, and
//   STA then infers clock-gating setup/hold checks between the two -- with the
//   full clock uncertainty and any useful skew the clock-tree tool puts on the
//   gate's clock pin. On the latch memories that produced ~600 setup and
//   ~1,380 hold violations that hold fixing could not close without breaking
//   setup.
//
//   CKLNQD is the library's posedge integrated clock gate
//   (clock_gating_integrated_cell : latch_posedge_precontrol): E|TE latched
//   while CP is low, Q = CP & latched value. Identical behaviour, but one
//   characterized cell, so STA times E against CP's rising edge (a normal
//   full-cycle enable check) and CTS treats it as a clock gate it can size.
//
// Drive: D1 is the smallest; CTS upsizes to CKLNQD2..8 where a gate drives a
// large subtree.
// -----------------------------------------------------------------------------
module prim_clock_gating #(
  parameter bit NoFpgaGate    = 1'b0,  // unused here; kept for interface parity
  parameter bit FpgaBufGlobal = 1'b1   // unused here; kept for interface parity
) (
  input        clk_i,
  input        en_i,
  input        test_en_i,
  output logic clk_o
);

  CKLNQD1BWP7T u_icg (
    .CP (clk_i),
    .E  (en_i),
    .TE (test_en_i),
    .Q  (clk_o)
  );

endmodule
