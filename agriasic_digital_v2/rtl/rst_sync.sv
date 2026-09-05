// -----------------------------------------------------------------------------
// Module: rst_sync
// Purpose:
//   2FF reset synchronizer: asynchronous assert, synchronous deassert.
//
// Contract (MAS section 8.2; Rev 4.3 baseline section 7, "single clock
// domain"):
//   rst_n_i may be asserted asynchronously -- a brown-out, a host reset pin,
//   a glitch -- and must take effect immediately. This synchronizer does NOT
//   delay assertion: it is wired as an async reset on its own flops, so a
//   falling rst_n_i clears rst_n_o the same instant, with no dependency on clk
//   running.
//
//   Deassertion is where synchronizers matter. Released asynchronously,
//   rst_n_i could land inside a setup/hold window of any downstream flop,
//   risking metastability across the whole design at once, right as
//   everything is trying to come out of reset together. This module holds
//   rst_n_o low for two full clk cycles after rst_n_i is observed high, so
//   every downstream flop sees a clean release edge.
//
// Placement: instantiate once per chip-boundary top (see the *_top.sv files
// that take an external rst_n), not redundantly at every internal block.
// -----------------------------------------------------------------------------
module rst_sync (
  input  logic clk,
  input  logic rst_n_i,   // raw, external, possibly asynchronous/glitchy
  output logic rst_n_o    // synchronized: async assert, sync deassert
);

  logic meta_q;

  always_ff @(posedge clk or negedge rst_n_i) begin
    if (!rst_n_i) begin
      meta_q  <= 1'b0;
      rst_n_o <= 1'b0;
    end else begin
      meta_q  <= 1'b1;
      rst_n_o <= meta_q;
    end
  end

endmodule
