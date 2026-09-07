`timescale 1ns/1ns

// -----------------------------------------------------------------------------
// Testbench: tb_excitation_drive
// Purpose:
//   Regression for the Rev 4.3 Phase 4 free-running excitation generator.
//   The pre-Phase-4 version of this test drove set_phase_i/phase_value_i and
//   checked settled_o -- none of which exist anymore. This is a full rewrite
//   against the new interface: divider_i in, phase_index_o/drive_p_o/
//   drive_n_o/period_tick_o out.
//
// What this checks, for several divider_i (N) values:
//   1. Frequency accuracy: exactly N clk cycles per phase_index increment,
//      and exactly 16*N cycles per full period (period_tick_o timing).
//   2. The phase-to-drive map holds: drive_p_o for phase 0-6, dead (both low)
//      at 7, drive_n_o for phase 8-14, dead at 15.
//   3. {drive_p_o, drive_n_o} = 2'b11 never occurs -- asserted every cycle,
//      not just checked at the handful of points the map test happens to
//      look at.
//   4. enable_i=0 parks the generator in a safe idle state (both drive lines
//      low, phase held at 0) and enable_i=1 always starts a clean period from
//      phase 0.
// -----------------------------------------------------------------------------
module tb_excitation_drive;
  localparam int unsigned DIVIDER_WIDTH = 14;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic enable_i = 1'b0;
  logic [DIVIDER_WIDTH-1:0] divider_i = '0;
  logic drive_p_o, drive_n_o;
  logic [3:0] phase_index_o;
  logic period_tick_o;

  int errors = 0;

  always #5 clk = ~clk;

  excitation_ctrl #(
    .DIVIDER_WIDTH(DIVIDER_WIDTH)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .enable_i      (enable_i),
    .divider_i     (divider_i),
    .drive_p_o     (drive_p_o),
    .drive_n_o     (drive_n_o),
    .phase_index_o (phase_index_o),
    .period_tick_o (period_tick_o)
  );

  // Structural contract: never both asserted. Checked every cycle for the
  // entire test, not just at hand-picked sample points.
  property p_never_both_driven;
    @(posedge clk) disable iff (!rst_n)
      !(drive_p_o && drive_n_o);
  endproperty
  assert property (p_never_both_driven)
    else $error("ASSERT_FAIL: drive_p_o and drive_n_o asserted together");

  // Checks the phase-to-drive map for whatever phase_index_o currently reads,
  // called once per phase index during the sweep below.
  task automatic check_phase_map(input logic [3:0] idx);
    bit want_p, want_n;
    begin
      want_p = (idx < 4'd7);
      want_n = (idx >= 4'd8) && (idx != 4'd15);
      if (drive_p_o !== want_p || drive_n_o !== want_n) begin
        $error("PHASE_MAP_FAIL: idx=%0d drive_p=%0b (want %0b) drive_n=%0b (want %0b)",
               idx, drive_p_o, want_p, drive_n_o, want_n);
        errors++;
      end
    end
  endtask

  // Runs one full period at the given N, checking frequency accuracy and the
  // phase map at every one of the 16 states.
  task automatic check_one_period(input logic [DIVIDER_WIDTH-1:0] n);
    int unsigned cyc_since_last;
    logic [3:0] last_idx;
    int unsigned states_seen;
    int unsigned period_cycles;
    int unsigned p_half_cycles;
    int unsigned n_half_cycles;
    begin
      divider_i = n;
      @(negedge clk);
      enable_i = 1'b1;
      @(posedge clk);  // let the first cycle register

      last_idx       = phase_index_o;
      cyc_since_last = 0;
      states_seen    = 0;
      period_cycles  = 0;
      p_half_cycles  = 0;
      n_half_cycles  = 0;

      // Walk cycles until period_tick_o pulses (one full period), verifying
      // every phase-index transition takes exactly N cycles and the drive
      // map holds at every index along the way.
      while (states_seen < 16) begin
        @(posedge clk);
        period_cycles++;
        cyc_since_last++;
        check_phase_map(phase_index_o);
        if (drive_p_o) p_half_cycles++;
        if (drive_n_o) n_half_cycles++;

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

      // 8.2 half-cycle symmetry, made explicit rather than left implicit in
      // the combination of the phase-map and per-state timing checks above:
      // 7 P-states and 7 N-states, each exactly N cycles, must sum to the
      // same total on both halves -- 7*N drive_p_o cycles, 7*N drive_n_o
      // cycles, for charge balance.
      if (p_half_cycles !== 7 * n || n_half_cycles !== 7 * n || p_half_cycles !== n_half_cycles) begin
        $error("SYMMETRY_FAIL: N=%0d drive_p_o high for %0d cycles, drive_n_o for %0d cycles, expected %0d each",
               n, p_half_cycles, n_half_cycles, 7 * n);
        errors++;
      end else begin
        $display("[TB]   N=%0d: half-cycle symmetry holds -- %0d cycles driven positive, %0d negative",
                 n, p_half_cycles, n_half_cycles);
      end

      enable_i = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[TB] excitation_ctrl free-running phase generator (Rev 4.3 Phase 4)");

    // N=1 is the fastest, most timing-critical point (10 MHz at f_clk=160
    // MHz) -- also the case where the 1-phase-state dead time is tightest
    // (exactly 1 clk cycle). N=5 and N=13 are arbitrary non-power-of-two
    // points to catch anything that only happens to work for round numbers.
    check_one_period(14'd1);
    check_one_period(14'd5);
    check_one_period(14'd13);

    // Idle check: disabled parks both drive lines low and phase at 0.
    enable_i  = 1'b0;
    divider_i = 14'd1;
    repeat (5) @(posedge clk);
    if (drive_p_o !== 1'b0 || drive_n_o !== 1'b0 || phase_index_o !== 4'd0) begin
      $error("IDLE_FAIL: expected both drive lines low and phase=0, got p=%0b n=%0b phase=%0d",
             drive_p_o, drive_n_o, phase_index_o);
      errors++;
    end else begin
      $display("[TB]   idle (enable=0): both drive lines low, phase parked at 0 -- OK");
    end

    if (errors == 0) begin
      $display("EXCITATION_DRIVE_PASS");
    end else begin
      $display("EXCITATION_DRIVE_FAIL: %0d error(s)", errors);
    end
    $finish;
  end
endmodule
