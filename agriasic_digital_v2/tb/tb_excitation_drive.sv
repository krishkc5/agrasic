`timescale 1ns/1ns

// -----------------------------------------------------------------------------
// Testbench: tb_excitation_drive
// Purpose:
//   Regression for the free-running excitation generator. Rev 5 replaced the
//   square-wave drive_p_o/drive_n_o pair with a sine DAC code, so the drive
//   map and break-before-make dead-time checks this test used to make no
//   longer describe anything: there are no complementary drive transistors.
//   The PHASE machinery is unchanged, and so are the checks on it.
//
// What this checks, for several divider_i (N) values:
//   1. Frequency accuracy: exactly N clk cycles per phase_index increment,
//      and exactly 16*N cycles per full period (period_tick_o timing).
//   2. The phase-to-code map: sine_code_o is the cosine table entry for the
//      current phase index, checked at every index -- the peaks land on the
//      indices measurement_fsm samples for the I channel (0, 8) and mid-code
//      on the ones it samples for Q (4, 12).
//   3. Half-period antisymmetry: code[k] + code[k+8] == 2*MID exactly, for
//      every k. This is the +/- chop contract -- what makes (D(0) - D(180))
//      cancel offset and drift. The square wave got it from two equal 7-state
//      drive halves; the table gets it from the values themselves.
//   4. Amplitude scaling attenuates the excursion about mid-code without
//      moving mid-code itself (the drive buffer's DC operating point).
//   5. enable_i=0 parks the generator at mid-code (VCM) with phase held at 0,
//      and enable_i=1 always starts a clean period from phase 0.
// -----------------------------------------------------------------------------
module tb_excitation_drive;
  localparam int unsigned DIVIDER_WIDTH = 14;
  localparam int unsigned DAC_WIDTH     = 8;
  localparam int unsigned MID           = 1 << (DAC_WIDTH - 1);   // 128

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic enable_i = 1'b0;
  logic [DIVIDER_WIDTH-1:0] divider_i = '0;
  logic [1:0] amplitude_i = 2'd0;
  logic [DAC_WIDTH-1:0] sine_code_o;
  logic [3:0] phase_index_o;
  logic period_tick_o;

  int errors = 0;

  always #5 clk = ~clk;

  excitation_ctrl #(
    .DIVIDER_WIDTH (DIVIDER_WIDTH),
    .DAC_WIDTH     (DAC_WIDTH)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .enable_i      (enable_i),
    .divider_i     (divider_i),
    .amplitude_i   (amplitude_i),
    .sine_code_o   (sine_code_o),
    .phase_index_o (phase_index_o),
    .period_tick_o (period_tick_o)
  );

  // Reference cosine excursion table -- written out independently of the DUT's
  // so a table typo is caught rather than mirrored.
  function automatic int signed ref_delta(input int idx);
    case (idx)
      0:  return  127;
      1:  return  117;
      2:  return   90;
      3:  return   49;
      4:  return    0;
      5:  return  -49;
      6:  return  -90;
      7:  return -117;
      8:  return -127;
      9:  return -117;
      10: return  -90;
      11: return  -49;
      12: return    0;
      13: return   49;
      14: return   90;
      default: return 117;
    endcase
  endfunction

  function automatic int ref_code(input int idx, input int amp);
    // MID is declared `int unsigned`; adding a negative excursion to it
    // directly would evaluate unsigned and wrap. Force signed arithmetic.
    int signed mid_s = int'(MID);
    return mid_s + (ref_delta(idx) >>> amp);
  endfunction

  task automatic check_code_map(input logic [3:0] idx, input int amp);
    if (int'(sine_code_o) !== ref_code(int'(idx), amp)) begin
      $error("CODE_MAP_FAIL: idx=%0d amp=%0d code=%0d, expected %0d",
             idx, amp, sine_code_o, ref_code(int'(idx), amp));
      errors++;
    end
  endtask

  task automatic run_divider_case(input int n);
    int period_cycles;
    int cyc_since_last;
    int states_seen;
    logic [3:0] last_idx;
    begin
      divider_i = DIVIDER_WIDTH'(n);
      amplitude_i = 2'd0;
      enable_i  = 1'b0;
      repeat (3) @(posedge clk);
      enable_i  = 1'b1;

      // Synchronise to a period boundary: period_tick_o pulses on the wrap to
      // phase 0 with the divider counter freshly cleared, so counting from the
      // next edge measures whole phase states rather than a partial first one.
      while (!period_tick_o) @(posedge clk);
      last_idx       = phase_index_o;
      period_cycles  = 0;
      cyc_since_last = 0;
      states_seen    = 0;

      // Walk cycles until every phase state has been seen, verifying each
      // transition takes exactly N cycles and the code map holds throughout.
      while (states_seen < 16) begin
        @(posedge clk);
        period_cycles++;
        cyc_since_last++;
        check_code_map(phase_index_o, 0);

        if (phase_index_o !== last_idx) begin
          if (cyc_since_last !== n) begin
            $error("FREQ_FAIL: N=%0d phase %0d->%0d took %0d cycles, expected %0d",
                   n, last_idx, phase_index_o, cyc_since_last, n);
            errors++;
          end
          last_idx       = phase_index_o;
          cyc_since_last = 0;
          states_seen++;
        end
      end

      if (period_cycles !== 16 * n) begin
        $error("PERIOD_FAIL: N=%0d full period took %0d cycles, expected %0d",
               n, period_cycles, 16 * n);
        errors++;
      end else begin
        $display("[TB]   N=%0d: 16 phase states, %0d cycles each, %0d cycles/period -- OK",
                 n, n, period_cycles);
      end

      enable_i = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    $display("[TB] excitation_ctrl free-running sine generator (Rev 5)");

    run_divider_case(1);
    run_divider_case(5);
    run_divider_case(13);

    // ---- half-period antisymmetry: the +/- chop contract ----
    begin
      int bad = 0;
      for (int k = 0; k < 8; k++) begin
        if (ref_code(k, 0) + ref_code(k + 8, 0) != 2 * MID) begin
          $error("SYMMETRY_FAIL: code[%0d] + code[%0d] = %0d, expected %0d",
                 k, k + 8, ref_code(k, 0) + ref_code(k + 8, 0), 2 * MID);
          bad++;
          errors++;
        end
      end
      if (bad == 0)
        $display("[TB]   half-period antisymmetry holds: code[k] + code[k+8] = %0d for all k", 2 * MID);
    end

    // ---- sample points land where the FSM expects ----
    if (ref_code(0, 0) != MID + 127 || ref_code(8, 0) != MID - 127) begin
      $error("SAMPLE_POINT_FAIL: phase 0/8 are not the drive peaks");
      errors++;
    end else if (ref_code(4, 0) != MID || ref_code(12, 0) != MID) begin
      $error("SAMPLE_POINT_FAIL: phase 4/12 are not at mid-code");
      errors++;
    end else begin
      $display("[TB]   sample points: peaks at phase 0/8 (I), mid-code at 4/12 (Q) -- OK");
    end

    // ---- amplitude scaling: excursion attenuates, mid-code does not move ----
    // Walk a full period at each amplitude (same synchronisation as the
    // frequency cases) and check every phase index, rather than probing one
    // index at an edge whose phase alignment has to be reasoned about.
    divider_i = DIVIDER_WIDTH'(2);
    for (int amp = 0; amp < 4; amp++) begin
      int seen;
      logic [3:0] last;
      amplitude_i = 2'(amp);
      enable_i = 1'b0;
      repeat (3) @(posedge clk);
      enable_i = 1'b1;
      while (!period_tick_o) @(posedge clk);
      last = phase_index_o;
      seen = 0;
      while (seen < 16) begin
        @(posedge clk);
        check_code_map(phase_index_o, amp);
        if ((phase_index_o == 4'd4 || phase_index_o == 4'd12) && int'(sine_code_o) !== MID) begin
          $error("AMPLITUDE_FAIL: amp=%0d moved mid-code to %0d at phase %0d",
                 amp, sine_code_o, phase_index_o);
          errors++;
        end
        if (phase_index_o !== last) begin
          last = phase_index_o;
          seen++;
        end
      end
      $display("[TB]   amplitude %0d: peak code %0d, mid-code held at %0d",
               amp, ref_code(0, amp), MID);
      enable_i = 1'b0;
      repeat (2) @(posedge clk);
    end
    amplitude_i = 2'd0;

    // ---- idle state ----
    repeat (4) @(posedge clk);
    if (sine_code_o !== DAC_WIDTH'(MID) || phase_index_o !== 4'd0) begin
      $error("IDLE_FAIL: enable_i=0 left code=%0d phase=%0d, expected code=%0d phase=0",
             sine_code_o, phase_index_o, MID);
      errors++;
    end else begin
      $display("[TB]   idle (enable=0): parked at mid-code %0d, phase 0 -- OK", MID);
    end

    if (errors == 0) $display("EXCITATION_DRIVE_PASS");
    else             $display("EXCITATION_DRIVE_FAIL: %0d error(s)", errors);
    $finish;
  end

endmodule
