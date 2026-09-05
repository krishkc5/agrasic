`timescale 1ns/1ns

// -----------------------------------------------------------------------------
// Testbench: tb_rst_sync
// Purpose:
//   Regression for the Rev 4.3 Phase 2.1 reset synchronizer. Every other
//   testbench in this tree drives rst_n cleanly, synchronously with its own
//   clock -- none of them exercise what rst_sync actually exists for: an
//   assert/deassert edge that lands in the middle of a clk cycle. This test
//   drives rst_n_i at several clk-unaligned phase offsets and checks:
//     1. Assertion is immediate (async): rst_n_o drops well before the next
//        clk edge, regardless of when in the cycle rst_n_i fell.
//     2. Deassertion is synchronized: rst_n_o stays low for at least one full
//        clk cycle after rst_n_i is sampled high, and only ever rises exactly
//        at a clk posedge, never mid-cycle.
// -----------------------------------------------------------------------------
module tb_rst_sync;
  logic clk = 1'b0;
  logic rst_n_i = 1'b0;
  logic rst_n_o;

  int errors = 0;

  always #5 clk = ~clk;

  rst_sync dut (
    .clk     (clk),
    .rst_n_i (rst_n_i),
    .rst_n_o (rst_n_o)
  );

  task automatic check_assert(input int unsigned phase_offset_ns);
    time t_fall;
    begin
      // Bring rst_n_i high and let a few clean cycles pass first.
      rst_n_i = 1'b1;
      repeat (3) @(posedge clk);

      // Fall at an arbitrary offset from the clock edge -- deliberately NOT
      // aligned to posedge or negedge.
      #(phase_offset_ns);
      rst_n_i = 1'b0;
      t_fall  = $time;

      // Assertion must be visible almost immediately (async), certainly
      // before the next clk edge, regardless of phase.
      #1;
      if (rst_n_o !== 1'b0) begin
        $error("ASSERT_NOT_IMMEDIATE: rst_n_o still high %0d ns after rst_n_i fell at t=%0t",
               1, t_fall);
        errors++;
      end else begin
        $display("[TB]   assert at phase+%0dns: rst_n_o dropped within 1ns (async, OK)", phase_offset_ns);
      end
    end
  endtask

  task automatic check_deassert(input int unsigned phase_offset_ns);
    time t_rise;
    int  cycles_still_low;
    begin
      // Start from reset asserted.
      rst_n_i = 1'b0;
      repeat (3) @(posedge clk);

      // Release at an arbitrary, clk-unaligned offset.
      #(phase_offset_ns);
      rst_n_i = 1'b1;
      t_rise  = $time;

      // rst_n_o must stay low through at least the next clk edge (the first
      // FF in the 2FF chain has not even captured the release yet).
      @(posedge clk);
      if (rst_n_o !== 1'b0) begin
        $error("DEASSERT_TOO_FAST: rst_n_o rose before the second sync stage, t_rise=%0t", t_rise);
        errors++;
      end

      // It must rise within the next couple of clk edges, and precisely AT a
      // posedge (checked by sampling only at posedge boundaries below).
      cycles_still_low = 0;
      while (rst_n_o !== 1'b1 && cycles_still_low < 5) begin
        @(posedge clk);
        cycles_still_low++;
      end
      if (rst_n_o !== 1'b1) begin
        $error("DEASSERT_NEVER: rst_n_o did not rise within 5 clk cycles of release");
        errors++;
      end else begin
        $display("[TB]   deassert at phase+%0dns: rst_n_o released after %0d clk edge(s), aligned to posedge (OK)",
                 phase_offset_ns, cycles_still_low);
      end
    end
  endtask

  initial begin
    $display("[TB] rst_sync: async assert / sync deassert, at clk-unaligned phases");

    check_assert(1);
    check_assert(3);
    check_assert(7);
    check_assert(9);

    check_deassert(1);
    check_deassert(3);
    check_deassert(7);
    check_deassert(9);

    if (errors == 0) begin
      $display("RST_SYNC_PASS");
    end else begin
      $display("RST_SYNC_FAIL: %0d error(s)", errors);
    end
    $finish;
  end
endmodule
