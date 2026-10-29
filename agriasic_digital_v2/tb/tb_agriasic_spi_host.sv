// -----------------------------------------------------------------------------
// tb_agriasic_spi_host -- host SPI port as bus master M4 (closes GAP-11)
//
// What this proves, in order:
//   A. The host can write and read DMEM over SPI **while the core is running**
//      its sweep -- no firmware cooperation, no handshake.
//   B. The host can read the peripheral window (MMIO STATUS).
//   C. Permissions are enforced in the interconnect, not trusted to the host:
//      IMEM and the debug module are both refused, and the refusal is visible
//      as a sticky error bit rather than silently returning garbage.
//   D. The sticky error survives until the host reads status, then clears.
//   E. The host learns the sweep is finished the ONLY way the chip allows --
//      by polling STATUS[6] (fw_done) over SPI -- and then reads a REAL
//      measurement result out of DMEM, the capability GAP-11 was about. The
//      poll is the mechanism by decision, not by omission: see the comment at
//      scenario E and "Completion signalling" in docs/interface_contract.md.
//   F. The TIA gain code decodes to three switch wires, and the retired
//      AFE_CTRL[1:0] field reads back as zero.
//   G. Abort and start-while-busy are handled, and abort wins when one write
//      asserts both.
//   H. The host can recover the WHOLE sweep, not just one word of it: every
//      point of every result array, read with the address auto-increment the
//      protocol specifies rather than one transaction per word. E proves the
//      path exists; H proves it carries the data a host actually needs.
//
// SPI timing follows the proven pattern in tb_agriasic_digital_spi_top: mode 0,
// MSB first, one bit per 240 ns against a 10 ns core clock, which is well
// inside the f_clk/16 ceiling spi_slave's oversampling imposes.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_agriasic_spi_host;

  localparam int unsigned ADC_WIDTH = 8;
  localparam logic [31:0] DMEM_BASE = 32'h0001_0000;
  localparam int unsigned NUM_FREQ_POINTS = 8;   // must match fw/fw.c
  // The sweep ladder fw.c walks, in the order it produces points. Scenario H
  // reads this back over SPI: without it a host has results but no idea which
  // frequency each one belongs to.
  localparam int EXP_DIV [0:7] = '{1, 10, 32, 100, 316, 1000, 3162, 10000};
  // Firmware's measurement configuration, mirrored from fw/fw.c main().
  // These exist only to DERIVE the completion timeout in scenario E, so the
  // bench does not carry a hard-coded cycle count that quietly stops
  // bounding anything the moment the sweep is re-banded or averaging raised.
  localparam int unsigned FW_MEASUREMENTS  = 2;        // NUM_MEASUREMENTS
  localparam int unsigned FW_SETTLE        = 2;        // REG_SETTLE
  localparam int unsigned FW_PAIR_LOG2     = 2;        // REG_PAIR_LOG2
  localparam int unsigned CLK_PERIOD_NS    = 10;
  localparam int unsigned POLL_INTERVAL_NS = 500_000;  // 0.5 ms, as a host would
  // Scratch for the concurrent-access probe, in the guard region between
  // the firmware's result block (0x000-0x0DF) and the stack (from 0x150),
  // so the firmware never writes it. Not 0x080 (now OUT_CUR_I[0]) and not
  // 0x100 (OUT_COUNT in the old map, still read as such elsewhere).
  localparam logic [31:0] SPI_SCRATCH = 32'h120;

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
    .dbg_cfg_exc_divider_o (), .dbg_cfg_conv_cycles_o (),
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

  // Several words in ONE transaction, leaning on the bridge's address
  // auto-increment (agriasic_spi_host.sv: addr_q <= addr_q + 4 at the end of
  // every data word). host_read32 opens a fresh transaction per word and so
  // never exercises that increment -- which is the documented protocol and
  // the only sane way for a host to pull 40 result words off the chip.
  logic [31:0] burst [0:7];
  task automatic host_read_burst(input logic [31:0] addr, input int unsigned n);
    logic [7:0] rx, b0, b1, b2, b3;
    begin
      cs_n = 1'b0; #480;
      spi_byte(8'h03, rx);
      send_addr(addr);
      for (int unsigned i = 0; i < n; i++) begin
        spi_byte(8'h00, b0);
        spi_byte(8'h00, b1);
        spi_byte(8'h00, b2);
        spi_byte(8'h00, b3);
        burst[i] = {b3, b2, b1, b0};
      end
      cs_n = 1'b1; #800;
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

  // The real host completion poll, and the only mechanism the chip offers:
  // a 0x03 READ of MMIO STATUS, truncated after ONE data byte.
  //
  // Not RDSR (0x05) -- that status byte is [0] bridge busy and [1] sticky
  // error only (agriasic_spi_host.sv header). It says nothing about the
  // measurement, so fw_done is reachable only through the MMIO word.
  //
  // Truncating is deliberate and legal. Data is little-endian within a word,
  // so STATUS[7:0] -- and with it bit 6, fw_done -- arrives FIRST; the other
  // three bytes carry nothing a host waiting on completion needs. Dropping
  // CS_N early ends the transaction and resets the framing, and a read
  // commits nothing, so six bytes on the wire replace nine. That every
  // transaction AFTER this one still works is itself the proof that ending a
  // read mid-word leaves the bridge clean.
  //
  // Spinning on it is safe: fw_done_q is cleared only by reset, by
  // run_clear_i (core_rst) or by a CTRL write (agriasic_rv32i_mmio.sv), never
  // by a read -- unlike the RDSR sticky-error bit, which clears when read.
  task automatic host_poll_fw_done(output logic [7:0] status_lsb);
    logic [7:0] rx;
    begin
      cs_n = 1'b0; #480;
      spi_byte(8'h03, rx);
      send_addr(32'h8000_0014);
      spi_byte(8'h00, status_lsb);
      cs_n = 1'b1; #800;
    end
  endtask

  // Check the 8 words of the last burst against one expected value. Prints a
  // SINGLE line when they all agree -- 40 individual OK lines would drown the
  // rest of the regression log -- but names every point that disagrees.
  task automatic expect_burst_all(input string name, input logic [31:0] exp);
    int bad;
    begin
      bad = 0;
      for (int unsigned k = 0; k < NUM_FREQ_POINTS; k++) begin
        if (burst[k] !== exp) begin
          $error("%s[%0d] = 0x%08x, expected 0x%08x", name, k, burst[k], exp);
          errors++; bad++;
        end
      end
      if (bad == 0)
        $display("[TB]   H: %s[0..%0d] all = 0x%08x OK",
                 name, NUM_FREQ_POINTS - 1, exp);
    end
  endtask

  // Same, against the per-point sweep ladder rather than one constant.
  task automatic expect_burst_ladder();
    int bad;
    begin
      bad = 0;
      for (int unsigned k = 0; k < NUM_FREQ_POINTS; k++) begin
        if (burst[k] !== 32'(EXP_DIV[k])) begin
          $error("OUT_DIV[%0d] = 0x%08x, expected %0d", k, burst[k], EXP_DIV[k]);
          errors++; bad++;
        end
      end
      if (bad == 0)
        $display("[TB]   H: OUT_DIV[0..%0d] = the fw sweep ladder %0d..%0d OK",
                 NUM_FREQ_POINTS - 1, EXP_DIV[0], EXP_DIV[NUM_FREQ_POINTS-1]);
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
  logic [7:0]  st;
  int unsigned sweep_cycles_est, max_polls, polls, early_idle;

  initial begin
    // 1->0->1 on reset: Ibex gates its own clock, so its async-reset flops need
    // a real negedge under Verilator's 2-state init.
    rst_n = 1; start_i = 1; repeat (12) @(posedge clk);
    rst_n = 0; start_i = 0; repeat (10) @(posedge clk);
    rst_n = 1; repeat (3)  @(posedge clk);
    start_i = 1;
    repeat (200) @(posedge clk);

    $display("[TB] host SPI port (bus master M4)");

    // ---- A. write/read DMEM while the core is mid-sweep ---------------------
    if (fw_halted) begin
      $error("firmware already finished -- A does not prove concurrent access");
      errors++;
    end
    // 0x100 (word 0x40) is in the guard region between the firmware's result
    // block (0x000-0x0DF) and the stack (from 0x150), so the firmware never
    // touches it. This probe used to sit at 0x080, chosen when the results
    // lived at 0x100+; 0x080 is now OUT_CUR_I[0] and the firmware overwrote
    // the probe with 240 mid-test, which is how the relayout was caught.
    host_write32(DMEM_BASE + SPI_SCRATCH, 32'hDEAD_BEEF);
    host_read32 (DMEM_BASE + SPI_SCRATCH, v);
    expect_eq("A: DMEM read-back (core running)", v, 32'hDEAD_BEEF);
    expect_eq("A: ram_array[SPI_SCRATCH/4] (hier)",
              dut.u_control_shell.u_mmio.u_dmem.ram_array[SPI_SCRATCH >> 2], 32'hDEAD_BEEF);

    // ---- B. peripheral window ----------------------------------------------
    host_read32(32'h8000_0014, v);          // STATUS
    $display("[TB]   B: MMIO STATUS via SPI = 0x%08x", v);
    host_status(st);
    expect_eq("B: no error after legal accesses", {24'd0, st[1]}, 32'd0);

    // ---- C. permissions: IMEM is refused -----------------------------------
    host_read32(32'h0000_0000, v);
    host_status(st);
    expect_eq("C: IMEM access refused (sticky error)", {24'd0, st[1]}, 32'd1);

    // ---- D. the error cleared when it was read, and the DM is refused too ---
    host_status(st);
    expect_eq("D: sticky error cleared by the status read", {24'd0, st[1]}, 32'd0);
    host_read32(32'h1A11_0000, v);
    host_status(st);
    expect_eq("D: debug module refused (sticky error)", {24'd0, st[1]}, 32'd1);
    host_status(st);

    // A refused access must not have disturbed memory.
    host_read32(DMEM_BASE + SPI_SCRATCH, v);
    expect_eq("D: DMEM intact after refusals", v, 32'hDEAD_BEEF);

    // ---- E. read a real result once the sweep finishes ----------------------
    // The host waits the way a real host must: by POLLING STATUS[6] (fw_done)
    // over SPI. Polling is the chip's completion mechanism by decision, not
    // by omission (2026-10-28): a bonded done pin was considered and declined,
    // since dbg_done_o is `dbg_`-prefixed -- testbench observability, never a
    // pad, per the MAS prefix table -- and promoting it would have cost pad 19.
    //
    // This loop used to spin on the hierarchical probe `fw_halted`, an oracle
    // no host has, which gated the entire result readout on a signal silicon
    // cannot see. The probe is still read below, but as a CROSS-CHECK that the
    // host-visible bit tells the truth -- never again as the gate.
    //
    // The bound is derived, not guessed. One pair is 4 phase points x 2
    // channels, and the phase order 0->180->90->270 wraps past the end of an
    // excitation period, so a pair costs about 2 periods of 16N cycles:
    //
    //   cycles ~= 16 * sum(N) * measurements * (settle + 2 * 2**pair_log2)
    //
    // At the firmware's settings that is 320 * 14621 = 4.68 Mcycles, against
    // the ~4.6 M the MAS records as measured -- close enough to trust. The
    // old hard-coded 8 M was fine for THIS sweep and nothing else: one more
    // decade point (N=10000) lands at 7.9 M and would have passed by 1%,
    // and pair_log2 = 4 overruns it outright.
    sweep_cycles_est = 0;
    for (int unsigned k = 0; k < NUM_FREQ_POINTS; k++)
      sweep_cycles_est += 16 * EXP_DIV[k] * FW_MEASUREMENTS *
                          (FW_SETTLE + 2 * (1 << FW_PAIR_LOG2));
    max_polls  = (2 * sweep_cycles_est * CLK_PERIOD_NS) / POLL_INTERVAL_NS;
    polls      = 0;
    early_idle = 0;
    do begin
      host_poll_fw_done(st);
      polls++;
      // STATUS[0] is the ENGINE's per-measurement busy, which returns to idle
      // 16 times during one sweep. This counts the polls that caught it idle
      // while the sweep was unfinished -- the polls at which a host watching
      // bit 0 would have declared victory and read a half-written block.
      //
      // Measured: 0 of 90 polls at a 0.5 ms interval. That makes bit 0 a
      // WORSE trap than a noisy count would, not a safer one: the gaps
      // between measurements are microseconds wide against a millisecond
      // poll, so a host polling bit 0 looks correct on the bench and fails
      // intermittently in the field. Reported, never asserted on in either
      // direction -- the count is a property of poll phasing, not of the RTL.
      if (!st[6] && !st[0]) early_idle++;
      if (!st[6]) #(POLL_INTERVAL_NS);
    end while (!st[6] && polls < max_polls);
    if (!st[6]) begin
      $error("E: fw_done never set -- %0d polls, bound %0d (~%0d ms of sweep)",
             polls, max_polls, (polls * POLL_INTERVAL_NS) / 1_000_000);
      errors++;
    end else begin
      $display("[TB]   E: host polled STATUS[6] fw_done, set after %0d polls (~%0d ms), bound %0d",
               polls, (polls * POLL_INTERVAL_NS) / 1_000_000, max_polls);
      $display("[TB]   E: polls that caught the engine idle mid-sweep = %0d of %0d",
               early_idle, polls);
      // If the host-visible bit ever disagreed with the internal flag, the
      // host would be lied to -- worse than having no flag at all.
      expect_eq("E: STATUS[6] agrees with the internal fw_done",
                {31'd0, fw_halted}, 32'd1);
      host_read32(DMEM_BASE + 32'h000, v);
      expect_eq("E: OUT_COUNT read over SPI", v, 32'd2);
      host_read32(DMEM_BASE + 32'h004, v);
      expect_eq("E: OUT_NUM_POINTS read over SPI", v, 32'(NUM_FREQ_POINTS));
      host_read32(DMEM_BASE + 32'h040, v);
      expect_eq("E: OUT_DV_I[0] read over SPI", v, 32'd400);
      host_read32(DMEM_BASE + 32'h080, v);
      expect_eq("E: OUT_CUR_I[0] read over SPI", v, 32'd240);
    end

    // ---- H. read the ENTIRE result block over SPI, in bursts ---------------
    // Runs here, after E and before F: F rewrites AFE_CTRL (and with it
    // mux_settle) and G aborts the engine, so both would disturb the results
    // this reads. Every sweep point sees the same four hold values from the
    // AFE model above, so every point must yield the same accumulators -- a
    // per-point indexing bug, a dropped point, or a burst that stops
    // incrementing shows up here and in none of A-E.
    if (st[6]) begin
      host_read_burst(DMEM_BASE + 32'h020, NUM_FREQ_POINTS);   // OUT_DIV[8]
      expect_burst_ladder();

      host_read_burst(DMEM_BASE + 32'h040, NUM_FREQ_POINTS);   // OUT_DV_I[8]
      expect_burst_all("OUT_DV_I", 32'd400);

      host_read_burst(DMEM_BASE + 32'h060, NUM_FREQ_POINTS);   // OUT_DV_Q[8]
      expect_burst_all("OUT_DV_Q", 32'd280);

      host_read_burst(DMEM_BASE + 32'h080, NUM_FREQ_POINTS);   // OUT_CUR_I[8]
      expect_burst_all("OUT_CUR_I", 32'd240);

      host_read_burst(DMEM_BASE + 32'h0A0, NUM_FREQ_POINTS);   // OUT_CUR_Q[8]
      expect_burst_all("OUT_CUR_Q", 32'd200);

      // Temperature is not implemented. The sentinel must survive the trip so
      // a host can tell "not implemented" from "zero degrees".
      host_read32(DMEM_BASE + 32'h008, v);
      expect_eq("H: OUT_TEMP sentinel reads -1, not 0", v, 32'hFFFF_FFFF);

      // A 40-word readout must not have tripped a bus error on the way.
      host_status(st);
      expect_eq("H: no sticky error across the whole readout", {24'd0, st[1]}, 32'd0);
    end

    // ---- F. TIA gain: a 2-bit code decodes to 3 switch wires ---------------
    // The voltage sense has a FIXED gain in analog, so only the TIA is checked;
    // AFE_CTRL[1:0] is reserved and must read back as zero.
    // Run last: writing AFE_CTRL also rewrites mux_settle, so doing this before
    // the sweep would perturb the measurement the earlier checks rely on.
    for (int code = 0; code < 4; code++) begin
      logic [2:0] expect_wires;
      logic [31:0] afe_word;
      expect_wires = (code == 0) ? 3'b001 : (code == 1) ? 3'b010 :
                     (code == 2) ? 3'b100 : 3'b111;
      // [15:8] mux_settle = 2 (its reset value), [5:4] amplitude = 0,
      // [3:2] tia_rf = code, [1:0] reserved -- written non-zero on purpose to
      // confirm the retired field is ignored and reads back as zero.
      afe_word = (32'd2 << 8) | (code << 2) | 2'b11;
      host_write32(32'h8000_003C, afe_word);
      expect_eq($sformatf("F: tia wires for code %0d", code), {29'd0, tia_rf},
                {29'd0, expect_wires});
      // AFE_CTRL must read back the CODE, not the decoded wires.
      host_read32(32'h8000_003C, v);
      expect_eq($sformatf("F: AFE_CTRL reads back tia=%0d, [1:0] reserved=0", code),
                v & 32'h0000_000F, {28'd0, code[1:0], 2'b00});
    end
    // No code may ever leave the TIA network fully open -- that would mean no
    // DC feedback path and a railed output.
    if (tia_rf == 3'b000) begin
      $error("F: a gain code decoded to all-open"); errors++;
    end

    // ---- G. abort, and start-while-busy rejection --------------------------
    // Run last, with firmware already parked in wfi, so aborting the engine
    // cannot strand the firmware waiting on a done that will never arrive.
    host_write32(32'h8000_0000, 32'h0000_0001);          // CTRL.start
    host_read32 (32'h8000_0014, v);
    expect_eq("G: engine busy after host start", v & 32'h1, 32'd1);

    host_write32(32'h8000_0000, 32'h0000_0001);          // start again, while busy
    host_read32 (32'h8000_0014, v);
    expect_eq("G: second start REJECTED, not silently dropped", (v >> 7) & 32'h1, 32'd1);
    expect_eq("G: still busy -- the run was not disturbed", v & 32'h1, 32'd1);

    host_write32(32'h8000_0000, 32'h0000_0002);          // CTRL.abort
    host_read32 (32'h8000_0014, v);
    expect_eq("G: abort clears busy", v & 32'h1, 32'd0);
    expect_eq("G: abort does not fake a done", (v >> 1) & 32'h1, 32'd0);
    expect_eq("G: engine FSM back in S_IDLE",
              {28'd0, 4'(dut.u_measurement_top.u_measurement_fsm.state_q)}, 32'd0);
    expect_eq("G: SAR back in S_IDLE",
              {29'd0, 3'(dut.u_measurement_top.u_sar_controller.state_q)}, 32'd0);

    host_write32(32'h8000_0000, 32'h0000_0080);          // CTRL.clear_err
    host_read32 (32'h8000_0014, v);
    expect_eq("G: clear_err clears the reject flag", (v >> 7) & 32'h1, 32'd0);

    host_write32(32'h8000_0000, 32'h0000_0001);          // start accepted again
    host_read32 (32'h8000_0014, v);
    expect_eq("G: restartable after abort", v & 32'h1, 32'd1);
    host_write32(32'h8000_0000, 32'h0000_0002);          // leave it idle

    // Abort wins over start when one write asserts both. Without that the two
    // disagreed: the bridge took the abort branch and left busy clear while the
    // sequencer accepted the start, so the engine ran while STATUS read idle.
    host_write32(32'h8000_0000, 32'h0000_0080);          // clear the flag first
    host_write32(32'h8000_0000, 32'h0000_0003);          // start | abort, engine idle
    host_read32 (32'h8000_0014, v);
    expect_eq("G: start+abort in one write does not start", v & 32'h1, 32'd0);
    expect_eq("G: ...and the dropped start is still flagged", (v >> 7) & 32'h1, 32'd1);
    expect_eq("G: ...engine left in S_IDLE",
              {28'd0, 4'(dut.u_measurement_top.u_measurement_fsm.state_q)}, 32'd0);
    host_write32(32'h8000_0000, 32'h0000_0080);          // tidy up

    if (errors == 0) $display("[TB] SPI_HOST_PASS -- all checks passed");
    else             $display("[TB] SPI_HOST_FAIL -- %0d error(s)", errors);
    $finish;
  end

  initial begin
    #150_000_000;   // scenario E waits for a full 8-point sweep, ~46 ms.
                    // This was 40 ms and tripped before the sweep finished.
    $error("tb_agriasic_spi_host: global timeout");
    $finish;
  end

endmodule
