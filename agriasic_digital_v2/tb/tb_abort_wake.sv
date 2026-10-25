// -----------------------------------------------------------------------------
// tb_abort_wake -- a host abort must WAKE the core, not strand it in wfi
//
// The engine's abort deliberately emits no done pulse, because done means "a
// fresh result is in the shadow registers" and an aborted run never snapshots
// them. But firmware waits in wfi, and the wake source used to be done alone:
// a host abort therefore left the core asleep forever with the sweep half
// finished. The wake is now done OR aborted, reported as SEPARATE status bits
// so that "woken" still never implies "a result is ready".
//
// What this proves, in order:
//   A. The core really is asleep in wfi with a measurement in flight before
//      the abort -- otherwise the whole test would be vacuous.
//   B. The abort wakes it, and STATUS says aborted-and-not-done, so firmware
//      can tell the difference.
//   C. Firmware then finishes its loop CLEANLY: it reaches FW_DONE instead of
//      hanging, and reports how many sweep points it actually completed.
//   D. It leaves the sticky ABORTED bit cleared, so the final wfi can really
//      sleep -- the wake is level sensitive, so a leftover bit would spin it.
//
// Harness (clock, AFE model, DUT wiring, SPI master) matches
// tb_agriasic_spi_host; only the scenario differs.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_abort_wake;

  localparam int unsigned ADC_WIDTH = 8;
  localparam logic [31:0] DMEM_BASE = 32'h0001_0000;

  // Must match NUM_FREQ_POINTS in fw/fw.c. Only used to judge "the sweep
  // stopped early", so an over-estimate here would make scenario C vacuous.
  localparam int unsigned NUM_FREQ_POINTS = 8;

  // Which sweep point to abort inside. Two competing requirements:
  //   long enough  -- a write32 over SPI takes ~1500 core cycles, so the run
  //                   must outlast that or it finishes before the abort lands
  //                   and the test measures nothing. Run time is ~157*N
  //                   cycles, so N=1000 gives ~157k cycles, a 100x margin.
  //   early enough -- reaching point k costs the sum of N over all points
  //                   before it. N=1000 is point 5, reached in ~156k cycles.
  //                   The old 3-point sweep used N=10000, which in the
  //                   8-point ladder is the LAST point and takes ~1.45M
  //                   cycles to reach -- and aborting there leaves only one
  //                   point outstanding, which barely counts as cutting the
  //                   sweep short.
  localparam logic [13:0] ABORT_TARGET_DIV = 14'd1000;   // 10 kHz, point 5

  logic clk = 1'b0;
  logic rst_n, start_i;
  int   errors = 0;

  // Host SPI pins
  logic sclk = 1'b0, cs_n = 1'b1, mosi = 1'b0;
  wire  miso, miso_oe;

  logic conv_start_o, busy_o, done_o;
  logic [ADC_WIDTH-1:0] sine_code_o, adc_dac_o;
  logic [1:0] mux_sel_o;
  logic adc_enable_o, adc_sample_o, adc_comp_i;
  logic signed [15:0] result_dv_i_o, result_dv_q_o, result_cur_i_o, result_cur_q_o;
  logic [2:0] tia_rf;
  logic [13:0] cfg_divider;

  always #5 clk = ~clk;

  // Two-channel AFE model, identical to tb_agriasic_rv32i_e2e: distinct targets
  // per channel so a swapped mux would fail rather than pass silently.
  logic [ADC_WIDTH-1:0] hold_dv_q, hold_cur_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (2'(dut.u_measurement_top.u_measurement_fsm.point_q))
        2'd0: begin hold_dv_q <= 8'd200; hold_cur_q <= 8'd170; end  // PT_0
        2'd1: begin hold_dv_q <= 8'd100; hold_cur_q <= 8'd110; end  // PT_180
        2'd2: begin hold_dv_q <= 8'd150; hold_cur_q <= 8'd140; end  // PT_90
        2'd3: begin hold_dv_q <= 8'd80;  hold_cur_q <= 8'd90;  end  // PT_270
      endcase
    end
  end
  wire [ADC_WIDTH-1:0] adc_target = (mux_sel_o == 2'd0) ? hold_dv_q : hold_cur_q;
  assign adc_comp_i = (adc_target >= adc_dac_o);

  agriasic_digital_rv32i_top #(
    .ADC_WIDTH         (ADC_WIDTH),
    .BOOT_DELAY_CYCLES (64),
    .IMEM_PRELOADED    (1'b1)
  ) dut (
    .clk (clk), .rst_n (rst_n), .gpio_start_i (start_i),
    .afe_conv_start_o (conv_start_o), .afe_sine_code_o (sine_code_o),
    .afe_mux_sel_o (mux_sel_o), .afe_adc_enable_o (adc_enable_o),
    .afe_sample_o (adc_sample_o), .afe_adc_dac_o (adc_dac_o),
    .afe_adc_comp_i (adc_comp_i),
    .dbg_busy_o (busy_o), .dbg_done_o (done_o),
    .dbg_result_dv_i_o (result_dv_i_o), .dbg_result_dv_q_o (result_dv_q_o),
    .dbg_result_cur_i_o (result_cur_i_o), .dbg_result_cur_q_o (result_cur_q_o),
    .dbg_cfg_pair_log2_o (), .dbg_cfg_settle_cycles_o (),
    .dbg_cfg_exc_divider_o (cfg_divider), .dbg_cfg_conv_cycles_o (),
    .dbg_cfg_mux_settle_o (), .dbg_cfg_amplitude_o (),
    .afe_tia_rf_o (tia_rf),
    .gpio_jtag_tck_i (1'b0), .gpio_jtag_tms_i (1'b1), .gpio_jtag_trst_ni (rst_n),
    .gpio_jtag_tdi_i (1'b0), .gpio_jtag_tdo_o (),
    .gpio_boot_sel_i (1'b0), .gpio_flash_sck_o (), .gpio_flash_cs_n_o (),
    .gpio_flash_mosi_o (), .gpio_flash_miso_i (1'b0), .gpio_boot_fail_o (),
    .gpio_spi_sclk_i (sclk), .gpio_spi_cs_n_i (cs_n), .gpio_spi_mosi_i (mosi),
    .gpio_spi_miso_o (miso), .gpio_spi_miso_oe_o (miso_oe)
  );

  wire fw_halted = dut.u_control_shell.done_o;

  // ---------------------------------------------------------------------------
  // SPI master (mode 0, MSB first)
  // ---------------------------------------------------------------------------
  task automatic spi_byte(input logic [7:0] tx, output logic [7:0] rx);
    int b;
    begin
      rx = 8'h00;
      for (b = 7; b >= 0; b--) begin
        mosi = tx[b];
        #80; sclk = 1'b1;
        #40; rx[b] = miso;
        #40; sclk = 1'b0;
        #80;
      end
      #480;   // inter-byte gap: spi_slave needs tx_data_i settled before the
              // next byte, and the bridge uses it to run its bus access
    end
  endtask

  task automatic send_addr(input logic [31:0] addr);
    logic [7:0] rx;
    begin
      spi_byte(addr[31:24], rx);
      spi_byte(addr[23:16], rx);
      spi_byte(addr[15:8],  rx);
      spi_byte(addr[7:0],   rx);
    end
  endtask

  task automatic host_read32(input logic [31:0] addr, output logic [31:0] data);
    logic [7:0] rx, b0, b1, b2, b3;
    begin
      cs_n = 1'b0; #480;
      spi_byte(8'h03, rx);
      send_addr(addr);
      spi_byte(8'h00, b0);
      spi_byte(8'h00, b1);
      spi_byte(8'h00, b2);
      spi_byte(8'h00, b3);
      cs_n = 1'b1; #800;
      data = {b3, b2, b1, b0};   // little endian within the word
    end
  endtask

  task automatic host_write32(input logic [31:0] addr, input logic [31:0] data);
    logic [7:0] rx;
    begin
      cs_n = 1'b0; #480;
      spi_byte(8'h02, rx);
      send_addr(addr);
      spi_byte(data[7:0],   rx);
      spi_byte(data[15:8],  rx);
      spi_byte(data[23:16], rx);
      spi_byte(data[31:24], rx);
      cs_n = 1'b1; #800;
    end
  endtask

  task automatic host_status(output logic [7:0] st);
    logic [7:0] rx;
    begin
      cs_n = 1'b0; #480;
      spi_byte(8'h05, rx);
      spi_byte(8'h00, st);
      cs_n = 1'b1; #800;
    end
  endtask

  task automatic expect_eq(input string name, input logic [31:0] got,
                           input logic [31:0] exp);
    begin
      if (got !== exp) begin
        $error("%s = 0x%08x, expected 0x%08x", name, got, exp);
        errors++;
      end else begin
        $display("[TB]   %s = 0x%08x OK", name, got);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  logic [31:0] v;
  int unsigned waited;

  wire core_sleep = dut.u_control_shell.core_sleep;

  // The firmware reacts far faster than a SPI status read completes: it wakes,
  // sees ABORTED, abandons the point and clears the bit in a few hundred
  // cycles, while a read32 over SPI takes ~1500. Latch what happened instead
  // of racing it. (That the bit is gone by the time the host can read it is
  // itself correct behaviour, and check D covers it.)
  logic saw_aborted       = 1'b0;
  logic done_after_abort  = 1'b0;
  logic woke_after_abort  = 1'b0;
  logic armed_b           = 1'b0;
  logic restarted         = 1'b0;
  logic reject_after_restart = 1'b0;
  always_ff @(posedge clk) begin
    // Armed by the testbench, because firmware's own init now issues an abort
    // (see scenario F) -- without the arming gate this would latch at boot and
    // the done monitor below would catch the sweep's legitimate completions.
    if (armed_b && dut.u_control_shell.u_mmio.meas_aborted_q) saw_aborted <= 1'b1;
    // Gated on saw_aborted, not on "the host sent the write": busy stays high
    // for the ~1500 cycles the SPI transaction takes to cross, so arming this
    // at send time would just re-observe the run we are trying to abort.
    if (saw_aborted && dut.u_control_shell.u_mmio.meas_done_q) done_after_abort <= 1'b1;
    // Latched, not sampled: the firmware wakes, abandons the point, clears the
    // sticky bit and re-parks in a few hundred cycles, which is faster than the
    // SPI transaction that delivered the abort can even finish. Polling a level
    // afterwards sees it already back asleep and cannot tell that apart from
    // never having woken at all.
    if (saw_aborted && !core_sleep) woke_after_abort <= 1'b1;
    // Scenario F: did the restarted firmware's FIRST start get rejected?
    if (restarted && dut.u_control_shell.u_mmio.start_rejected_q)
      reject_after_restart <= 1'b1;
  end

  initial begin
    rst_n = 1; start_i = 1; repeat (12) @(posedge clk);
    rst_n = 0; start_i = 0; repeat (10) @(posedge clk);
    rst_n = 1; repeat (4)  @(posedge clk);
    start_i = 1;

    $display("[TB] abort must wake the core, not strand it in wfi");

    // ---- A. get the core asleep inside a LONG sweep point -----------------
    // Three conditions, all load bearing. Asleep proves the wake path is the
    // only way out; busy proves there is a real run to abort; and a large
    // divider is what makes the abort land at all -- see ABORT_TARGET_DIV.
    waited = 0;
    while (!(core_sleep && busy_o && cfg_divider == ABORT_TARGET_DIV) && waited < 3000000) begin
      @(posedge clk);
      waited++;
    end
    expect_eq("A: core asleep in wfi, long run in flight",
              {31'd0, core_sleep && busy_o && (cfg_divider == ABORT_TARGET_DIV)}, 32'd1);
    if (!(core_sleep && busy_o && cfg_divider == ABORT_TARGET_DIV)) begin
      $display("[TB] ABORT_WAKE_FAIL -- could not reach the state under test");
      $finish;
    end
    $display("[TB]   reached after %0d cycles (divider=%0d)", waited, cfg_divider);

    // ---- B. abort, and check it wakes without claiming a result -----------
    armed_b = 1'b1;
    host_write32(32'h8000_0000, 32'h0000_0002);          // CTRL.abort

    expect_eq("B: ABORTED was set by the abort", {31'd0, saw_aborted}, 32'd1);
    // The whole reason the two bits stay separate: the core is woken without
    // anything ever claiming that a fresh result exists.
    expect_eq("B: done never set after the abort -- no result claimed",
              {31'd0, done_after_abort}, 32'd0);

    // ---- C. the core leaves wfi and the loop finishes cleanly -------------
    // Wait on fw_halted, which is sticky, rather than on any transient.
    waited = 0;
    while (!fw_halted && waited < 8000000) begin
      @(posedge clk);
      waited++;
    end

    // This is the check that fails outright if the wake source is done alone:
    // without ABORTED feeding the wake, the core stays in wfi forever here.
    expect_eq("C: abort woke the core out of wfi", {31'd0, woke_after_abort}, 32'd1);
    expect_eq("C: firmware reached FW_DONE instead of hanging", {31'd0, fw_halted}, 32'd1);
    $display("[TB]   firmware parked %0d cycles after the abort", waited);

    expect_eq("C: engine left idle", {31'd0, busy_o}, 32'd0);
    expect_eq("C: engine FSM in S_IDLE",
              {28'd0, 4'(dut.u_measurement_top.u_measurement_fsm.state_q)}, 32'd0);

    // It stopped early, and said so: fewer than the full point count.
    host_read32 (32'h0001_0004, v);                      // OUT_NUM_POINTS (map relaid)
    $display("[TB]   OUT_NUM_POINTS = %0d (%0d would be a full sweep)", v, NUM_FREQ_POINTS);
    if (v >= 32'(NUM_FREQ_POINTS)) begin
      $error("C: sweep reported complete despite being aborted");
      errors++;
    end else begin
      $display("[TB]   C: aborted sweep reports a partial point count OK");
    end

    // ---- D. the sticky bit is cleared, so the park wfi can really sleep ---
    host_read32 (32'h8000_0014, v);
    expect_eq("D: firmware cleared the sticky ABORTED bit", (v >> 8) & 32'h1, 32'd0);
    expect_eq("D: core sleeping again in its park loop", {31'd0, core_sleep}, 32'd1);

    // ---- E. aborting an already-parked core must NOT spin it --------------
    // The mirror image of the bug this testbench exists for. The wake is level
    // sensitive and ABORTED is sticky, so an abort arriving after FW_DONE would
    // hold irq_fast[0] high with nothing left to clear it -- firmware has run
    // its clear path for the last time -- and `park: wfi; j park` would spin at
    // full power forever. Waking a core that has finished achieves nothing.
    host_write32(32'h8000_0000, 32'h0000_0002);          // CTRL.abort, core parked
    host_read32 (32'h8000_0014, v);
    expect_eq("E: host still sees ABORTED in STATUS", (v >> 8) & 32'h1, 32'd1);
    expect_eq("E: ...but the parked core stays asleep", {31'd0, core_sleep}, 32'd1);

    // Hold it long enough that a spinning park loop could not hide.
    repeat (2000) @(posedge clk);
    expect_eq("E: still asleep 2000 cycles later -- no hot spin",
              {31'd0, core_sleep}, 32'd1);

    // ---- F. a core reset must not leave stale run state behind ------------
    // A core reset (gpio_start_i dropped) does NOT reset the engine or the
    // bridge's run state: the bridge survives a core reset on purpose so a
    // debugger can still read results, and run_clear_i only clears FW_DONE and
    // TRAP_SEEN. So firmware can come up with a measurement still in flight
    // from its previous incarnation. Its first CTRL.START would be rejected as
    // busy, it would sleep, and it would then wake on the OLD run's done and
    // store a result measured under the previous configuration as point 0.
    // Firmware's init therefore aborts before it configures anything.
    host_write32(32'h8000_0000, 32'h0000_0001);          // host starts a long run
                                                         // (divider is still ABORT_TARGET_DIV,
                                                         //  left there by the aborted point)
    host_read32 (32'h8000_0014, v);
    expect_eq("F: long run in flight before the core reset", v & 32'h1, 32'd1);

    start_i = 1'b0;                                      // hold the core
    repeat (200) @(posedge clk);
    expect_eq("F: FW_DONE cleared -- the core really was reset",
              {31'd0, fw_halted}, 32'd0);
    restarted = 1'b1;
    start_i = 1'b1;                                      // release it again

    // The restarted firmware reconfigures to point 0 (10 MHz, ~1350 cycles),
    // so a genuinely fresh completion shows up quickly.
    waited = 0;
    while (!dut.u_control_shell.u_mmio.meas_done_q && waited < 400000) begin
      @(posedge clk);
      waited++;
    end
    expect_eq("F: a FRESH measurement completed after the restart",
              {31'd0, dut.u_control_shell.u_mmio.meas_done_q}, 32'd1);
    $display("[TB]   fresh completion %0d cycles after release", waited);
    expect_eq("F: restarted firmware's first start was NOT rejected",
              {31'd0, reject_after_restart}, 32'd0);

    if (errors == 0) $display("[TB] ABORT_WAKE_PASS -- all checks passed");
    else             $display("[TB] ABORT_WAKE_FAIL -- %0d error(s)", errors);
    $finish;
  end

  initial begin
    #150_000_000;   // 8-point sweep is ~4.6 Mcycles = ~46 ms; leave headroom
    $display("[TB] ABORT_WAKE_FAIL -- global timeout (core most likely stranded in wfi)");
    $finish;
  end

endmodule
