// -----------------------------------------------------------------------------
// Power-up end-to-end testbench: boot -> IMEM -> firmware -> results -> park.
//
// One reset release and nothing else -- the flow the chip runs on its own.
// IMEM starts EMPTY (IMEM_PRELOADED=0, IMEM_INIT_FILE=""), so every
// instruction the core executes was put there by the boot FSM. The boot source
// is the only thing that changes between the two builds:
//
//   BOOT_FROM_FLASH = 0  (boot_rom_e2e.sh -> waves/boot_rom_e2e.fst)
//       Strap low, no flash on the board. The boot FSM shadow-loads the golden
//       image from the on-die ROM (fw/golden), one word per cycle.
//   BOOT_FROM_FLASH = 1  (boot_flash_e2e.sh -> waves/boot_flash_e2e.fst)
//       Strap high, a behavioural SPI NOR holds fw/agriasic_fw_flash.hex. The
//       boot FSM reads the 16-byte header and the payload over SPI, writes
//       IMEM a word at a time and checks the CRC.
//
// Either way the core is then released and the firmware runs the full 8-point
// sweep to FW_DONE and parks in wfi. Checks, in the order the chip does them:
//   1. No instruction fetch until the image is in and fw_valid is set.
//   2. Flash pins: idle for the whole boot (ROM), or driven and then released
//      (flash).
//   3. The copy itself: one bus write per image word, at consecutive
//      addresses, carrying the expected word for that address. Boot ends in
//      DONE from the right source with no error, and IMEM then matches the
//      image word for word.
//   4. The firmware sweep, with the same result checks as tb_agriasic_rv32i_e2e.
//   5. wfi sleeps during the measurements and in the final park loop.
//
// Unlike tb_agriasic_rv32i_e2e (IMEM preloaded, boot FSM in S_SKIP) this boots
// for real; unlike tb_agriasic_flash_boot (seven scenarios, five resets) it is
// one clean pass, for a demo or a first look at the waveform.
//
// ADC model and expected results: same as tb_agriasic_rv32i_e2e (see there).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_agriasic_boot_e2e #(
  parameter bit BOOT_FROM_FLASH = 1'b0   // set with verilator -GBOOT_FROM_FLASH=1
);

  localparam int unsigned ADC_WIDTH   = 8;
  localparam int unsigned IMAGE_WORDS = 256;
  localparam string       SRC_NAME    = BOOT_FROM_FLASH ? "SPI flash" : "golden ROM";
  localparam string       TAG         = BOOT_FROM_FLASH ? "FLASH" : "ROM";

  logic clk = 1'b0;
  logic rst_n;
  logic start_i;

  logic conv_start_o, busy_o, done_o;
  logic [ADC_WIDTH-1:0] sine_code_o;
  logic [1:0] mux_sel_o;
  logic adc_enable_o, adc_sample_o;
  logic [ADC_WIDTH-1:0] adc_dac_o;
  logic adc_comp_i;
  logic signed [15:0] result_dv_i_o, result_dv_q_o, result_cur_i_o, result_cur_q_o;
  logic [3:0]  cfg_pair_log2_o;
  logic [7:0]  cfg_settle_cycles_o;
  logic [13:0] cfg_exc_divider_o;
  logic [7:0]  cfg_conv_cycles_o;
  logic flash_sck, flash_cs_n, flash_mosi, flash_miso;
  logic boot_fail;

  always #5 clk = ~clk;

  // Rev 5 two-channel AFE model, identical to tb_agriasic_rv32i_e2e.
  logic [ADC_WIDTH-1:0] hold_dv_q, hold_cur_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (2'(dut.u_measurement_top.u_measurement_fsm.point_q))
        4'd0: begin hold_dv_q <= 8'd200; hold_cur_q <= 8'd170; end  // PT_0   (0 deg)
        4'd1: begin hold_dv_q <= 8'd100; hold_cur_q <= 8'd110; end  // PT_180 (180 deg)
        4'd2: begin hold_dv_q <= 8'd150; hold_cur_q <= 8'd140; end  // PT_90  (90 deg)
        4'd3: begin hold_dv_q <= 8'd80; hold_cur_q <= 8'd90; end  // PT_270 (270 deg)
        default: begin end
      endcase
    end
  end
  wire [ADC_WIDTH-1:0] adc_target = (mux_sel_o == 2'd0) ? hold_dv_q : hold_cur_q;
  assign adc_comp_i = (adc_target >= adc_dac_o);


  agriasic_digital_rv32i_top #(
    .ADC_WIDTH         (ADC_WIDTH),
    .BOOT_DELAY_CYCLES (64),
    .IMEM_PRELOADED    (1'b0),
    .IMEM_INIT_FILE    ("")          // program memory starts empty
  ) dut (
    .clk(clk), .rst_n(rst_n), .gpio_start_i(start_i),
    .afe_conv_start_o(conv_start_o), .afe_sine_code_o(sine_code_o), .afe_mux_sel_o(mux_sel_o),
    .afe_adc_enable_o(adc_enable_o), .afe_sample_o(adc_sample_o), .afe_adc_dac_o(adc_dac_o),
    .afe_adc_comp_i(adc_comp_i), .dbg_busy_o(busy_o), .dbg_done_o(done_o),
    .dbg_result_dv_i_o(result_dv_i_o), .dbg_result_dv_q_o(result_dv_q_o),
    .dbg_result_cur_i_o(result_cur_i_o), .dbg_result_cur_q_o(result_cur_q_o),
    .dbg_cfg_pair_log2_o(cfg_pair_log2_o), .dbg_cfg_settle_cycles_o(cfg_settle_cycles_o),
    .dbg_cfg_exc_divider_o(cfg_exc_divider_o), .dbg_cfg_conv_cycles_o(cfg_conv_cycles_o),
    .dbg_cfg_mux_settle_o(), .dbg_cfg_amplitude_o(), .afe_tia_rf_o(),
    // JTAG idle: TAP held in reset, no debugger attached in this test.
    .gpio_jtag_tck_i(1'b0), .gpio_jtag_tms_i(1'b1), .gpio_jtag_trst_ni(rst_n), .gpio_jtag_tdi_i(1'b0), .gpio_jtag_tdo_o(),
    // The strap is a board tie: high selects the flash, low the golden ROM.
    .gpio_boot_sel_i(BOOT_FROM_FLASH),
    .gpio_flash_sck_o(flash_sck), .gpio_flash_cs_n_o(flash_cs_n), .gpio_flash_mosi_o(flash_mosi), .gpio_flash_miso_i(flash_miso),
    .gpio_boot_fail_o(boot_fail),
    // No host on the M4 SPI port: deselected and idle.
    .gpio_spi_cs_n_i(1'b1), .gpio_spi_sclk_i(1'b0), .gpio_spi_mosi_i(1'b0),
    .gpio_spi_miso_o(), .gpio_spi_miso_oe_o()
  );

  if (BOOT_FROM_FLASH) begin : g_flash
    tb_spi_flash_model #(.IMAGE("agriasic_fw_flash.hex")) flash (
      .sck_i(flash_sck), .cs_n_i(flash_cs_n), .mosi_i(flash_mosi), .miso_o(flash_miso)
    );
  end else begin : g_no_flash
    assign flash_miso = 1'b1;   // no part on the board; MISO pulled up
  end

  wire        fw_halted  = dut.u_control_shell.done_o;
  wire        fw_valid   = dut.u_control_shell.fw_valid;
  wire        core_rst_n = dut.u_control_shell.core_rst_n;
  wire        core_sleep = dut.u_control_shell.core_sleep;
  wire        instr_req  = dut.u_control_shell.instr_req;
  wire        trap_seen  = dut.u_control_shell.trap_seen;
  wire [3:0]  boot_state = 4'(dut.u_control_shell.u_boot.state_q);
  wire [2:0]  boot_err   = dut.u_control_shell.u_boot.err_q;
  wire [31:0] boot_status = dut.u_control_shell.u_boot.boot_status_o;
  wire        boot_req   = dut.u_control_shell.boot_req;
  wire        boot_gnt   = dut.u_control_shell.boot_gnt;
  wire        boot_we    = dut.u_control_shell.boot_we;
  wire [31:0] boot_addr  = dut.u_control_shell.boot_addr;
  wire [31:0] boot_wdata = dut.u_control_shell.boot_wdata;

  localparam logic [3:0] S_WRITE = 4'd5, S_DONE = 4'd7, S_FAIL = 4'd8, S_ROM = 4'd10;
  localparam logic [1:0] SRC_ROM = 2'd1, SRC_FLASH = 2'd2;

  // The image the boot FSM should write into IMEM. ROM: the golden hex the ROM
  // was generated from, length from the DUT (see tb_agriasic_flash_boot for
  // why). Flash: the payload of the very bytes the flash model holds, decoded
  // little-endian after the 16-byte header, length from the header.
  logic [31:0] exp_img [0:IMAGE_WORDS-1];
  logic [7:0]  flash_bytes [0:16 + 4*IMAGE_WORDS - 1];
  int unsigned exp_words;
  logic [15:0] exp_version;
  initial begin
    for (int i = 0; i < IMAGE_WORDS; i++) exp_img[i] = 32'h0000_0000;
    if (BOOT_FROM_FLASH) begin
      for (int i = 0; i < $size(flash_bytes); i++) flash_bytes[i] = 8'hFF;
      $readmemh("agriasic_fw_flash.hex", flash_bytes);
      exp_words   = {flash_bytes[7], flash_bytes[6], flash_bytes[5], flash_bytes[4]} / 4;
      exp_version = {flash_bytes[9], flash_bytes[8]};
      for (int i = 0; i < exp_words; i++)
        exp_img[i] = {flash_bytes[16 + 4*i + 3], flash_bytes[16 + 4*i + 2],
                      flash_bytes[16 + 4*i + 1], flash_bytes[16 + 4*i]};
    end else begin
      $readmemh("agriasic_fw_golden.hex", exp_img);
      exp_words   = int'(dut.ROM_USED_WORDS);
      exp_version = 16'd0;   // a ROM boot reports version 0
    end
  end

  // Scratch RAM result map -- see tb_agriasic_rv32i_e2e / fw.c.
  localparam int W_COUNT      = 'h000 / 4;
  localparam int W_NUM_POINTS = 'h004 / 4;
  localparam int W_TEMP       = 'h008 / 4;
  localparam int W_DIV        = 'h020 / 4;
  localparam int W_DV_I       = 'h040 / 4;
  localparam int W_DV_Q       = 'h060 / 4;
  localparam int W_CUR_I      = 'h080 / 4;
  localparam int W_CUR_Q      = 'h0A0 / 4;

  localparam int NUM_FREQ_POINTS  = 8;   // must match fw/fw.c
  localparam int EXP_DIV [0:7] = '{1, 10, 32, 100, 316, 1000, 3162, 10000};
  localparam int NUM_MEASUREMENTS = 2;

  int errors = 0;
  int unsigned cycles, measurements_seen;

  always_ff @(posedge clk) begin
    if (!rst_n) measurements_seen <= 0;
    else if (done_o) measurements_seen <= measurements_seen + 1;
  end

  // --------------------------------------------------------------------------
  // 1-3. Boot monitors
  // --------------------------------------------------------------------------
  // The core must not fetch from IMEM before the boot has finished: until
  // fw_valid it would be executing a half-written image. Flash pin activity
  // is counted over the same window -- zero is required for a ROM boot.
  int unsigned early_fetches, flash_activity;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      early_fetches  <= 0;
      flash_activity <= 0;
    end else if (!fw_valid) begin
      if (instr_req) early_fetches <= early_fetches + 1;
      if (flash_cs_n !== 1'b1 || flash_sck !== 1'b0) flash_activity <= flash_activity + 1;
    end
  end

  // Every IMEM write the boot FSM makes (S_ROM for the ROM, S_WRITE for the
  // flash): count them, and check each lands at the next word address with
  // the expected word for that address.
  int unsigned copy_words, copy_bad, copy_first_cycle, copy_last_cycle, boot_cycle;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      copy_words <= 0; copy_bad <= 0; boot_cycle <= 0;
      copy_first_cycle <= 0; copy_last_cycle <= 0;
    end else begin
      boot_cycle <= boot_cycle + 1;
      if ((boot_state == S_ROM || boot_state == S_WRITE) && boot_req && boot_gnt) begin
        if (copy_words == 0) copy_first_cycle <= boot_cycle;
        copy_last_cycle <= boot_cycle;
        if (!boot_we || boot_addr !== 32'(copy_words * 4) ||
            boot_wdata !== exp_img[copy_words]) begin
          if (copy_bad < 4)
            $error("IMEM write %0d: we=%0b addr=0x%08x data=0x%08x, expected addr=0x%08x data=0x%08x",
                   copy_words, boot_we, boot_addr, boot_wdata, copy_words * 4, exp_img[copy_words]);
          copy_bad <= copy_bad + 1;
        end
        copy_words <= copy_words + 1;
      end
    end
  end

  // --------------------------------------------------------------------------
  // 4-5. Run monitors (as in tb_agriasic_rv32i_e2e)
  // --------------------------------------------------------------------------
  int unsigned conv_high_run;
  always_ff @(posedge clk) begin
    if (!rst_n) conv_high_run <= 0;
    else if (conv_start_o) begin
      conv_high_run <= conv_high_run + 1;
      if (conv_high_run >= 1) begin
        $error("afe_conv_start_o held high for more than one cycle");
        errors <= errors + 1;
      end
    end else begin
      conv_high_run <= 0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && busy_o && done_o) begin
      $error("dbg_busy_o and dbg_done_o both high at cycle %0d", cycles);
      errors <= errors + 1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && trap_seen) begin
      $error("TRAP_SEEN: firmware entered the trap handler at cycle %0d", cycles);
      errors <= errors + 1;
    end
  end

  property p_sleep_no_fetch;
    @(posedge clk) disable iff (!rst_n)
      core_sleep && core_rst_n |-> !instr_req;
  endproperty
  assert property (p_sleep_no_fetch)
    else $error("SLEEP_FAIL: instruction fetch issued while core_sleep_o was high");

  // Count sleep only once the core is out of reset: Ibex reports core_sleep
  // while it is held, which would otherwise pass the "it slept" check for free.
  int unsigned frozen_cycles;
  always_ff @(posedge clk) begin
    if (!rst_n) frozen_cycles <= 0;
    else if (core_sleep && core_rst_n) frozen_cycles <= frozen_cycles + 1;
  end

  task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] want);
    if (got !== want) begin
      $error("%s = 0x%08x, expected 0x%08x", what, got, want); errors++;
    end else $display("[TB]   %s = 0x%08x OK", what, got);
  endtask

  task automatic check_word(string name, int idx, logic [31:0] expected);
    logic [31:0] actual;
    begin
      actual = dut.u_control_shell.u_mmio.u_dmem.ram_array[idx];
      if (actual !== expected) begin
        $error("%s (word %0d) = 0x%08x, expected 0x%08x", name, idx, actual, expected);
        errors++;
      end else begin
        $display("[TB]   %s = %0d OK", name, $signed(actual));
      end
    end
  endtask

  initial begin
    // The one and only reset. start_i is high throughout: the core runs as
    // soon as the boot FSM says the image is valid.
    rst_n = 1'b0; start_i = 1'b1;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    $display("[TB] reset released: boot source %s, IMEM empty, %0d-word image expected",
             SRC_NAME, exp_words);

    // ---- boot: image -> IMEM ------------------------------------------------
    // A flash boot is ~80,000 cycles at the default SPI divider; a ROM boot ~150.
    cycles = 0;
    while (boot_state != S_DONE && boot_state != S_FAIL && cycles < 200000) begin
      @(posedge clk); cycles++;
    end
    $display("[TB] BOOT: finished in %0d cycles, state=%0d err=%0d", cycles, boot_state, boot_err);
    expect_eq("boot state DONE", {28'd0, boot_state}, {28'd0, S_DONE});
    expect_eq("boot error", {29'd0, boot_err}, 32'd0);
    expect_eq($sformatf("BOOT_STATUS source = %s", SRC_NAME), (boot_status >> 12) & 32'h3,
              {30'd0, BOOT_FROM_FLASH ? SRC_FLASH : SRC_ROM});
    expect_eq("BOOT_STATUS image version", boot_status >> 16, {16'd0, exp_version});
    expect_eq("gpio_boot_fail_o", {31'd0, boot_fail}, 32'd0);
    expect_eq("IMEM writes by the boot FSM", copy_words, exp_words);
    expect_eq("IMEM writes with a wrong address or word", copy_bad, 32'd0);
    expect_eq("instruction fetches before fw_valid", early_fetches, 32'd0);
    if (BOOT_FROM_FLASH) begin
      if (flash_activity == 0) begin
        $error("flash boot never drove the flash pins"); errors++;
      end else $display("[TB]   flash pins active for %0d cycles during boot OK", flash_activity);
      expect_eq("flash CS released after boot", {31'd0, flash_cs_n}, 32'd1);
    end else begin
      expect_eq("flash pins touched during boot (cycles)", flash_activity, 32'd0);
    end
    $display("[TB] BOOT: %0d words written to IMEM, cycles %0d..%0d after reset",
             copy_words, copy_first_cycle, copy_last_cycle);
    begin
      int bad = 0;
      for (int i = 0; i < exp_words; i++)
        if (dut.u_control_shell.u_imem.mem_array[i] !== exp_img[i]) begin
          if (bad < 4) $error("IMEM[%0d] = 0x%08x, expected 0x%08x",
                              i, dut.u_control_shell.u_imem.mem_array[i], exp_img[i]);
          bad++;
        end
      if (bad) errors++;
      else $display("[TB]   IMEM matches the %s image, %0d words OK", SRC_NAME, exp_words);
    end

    @(posedge clk);
    expect_eq("fw_valid", {31'd0, fw_valid}, 32'd1);
    repeat (2) @(posedge clk);
    expect_eq("core released (core_rst_n)", {31'd0, core_rst_n}, 32'd1);

    // ---- run: firmware sweep to FW_DONE -------------------------------------
    // Budget as in tb_agriasic_rv32i_e2e: the N=10000 point alone settles for
    // 320,000 cycles.
    cycles = 0;
    while (!fw_halted && cycles < 8000000) begin @(posedge clk); cycles++; end
    if (!fw_halted) begin
      $error("TIMEOUT: firmware did not reach FW_DONE within %0d cycles", cycles);
      errors++;
    end else begin
      $display("[TB] RUN: firmware reached FW_DONE after %0d cycles (%0d measurements)",
               cycles, measurements_seen);
    end
    repeat (5) @(posedge clk);   // let the final stores retire

    check_word("OUT_COUNT",      W_COUNT,      32'(NUM_MEASUREMENTS));
    check_word("OUT_NUM_POINTS", W_NUM_POINTS, 32'(NUM_FREQ_POINTS));
    check_word("OUT_TEMP",       W_TEMP,       32'hFFFFFFFF);  // sentinel -1
    for (int p = 0; p < NUM_FREQ_POINTS; p++)
      check_word($sformatf("OUT_DIV[%0d] (%0d Hz)", p, 10_000_000 / EXP_DIV[p]),
                 W_DIV + p, 32'(EXP_DIV[p]));
    for (int p = 0; p < NUM_FREQ_POINTS; p++) begin
      check_word($sformatf("OUT_DV_I[%0d]",  p), W_DV_I  + p, 32'd400);
      check_word($sformatf("OUT_DV_Q[%0d]",  p), W_DV_Q  + p, 32'd280);
      check_word($sformatf("OUT_CUR_I[%0d]", p), W_CUR_I + p, 32'd240);
      check_word($sformatf("OUT_CUR_Q[%0d]", p), W_CUR_Q + p, 32'd200);
    end
    expect_eq("cfg_pair_log2", {28'd0, cfg_pair_log2_o}, 32'd2);
    expect_eq("measurements completed", 32'(measurements_seen),
              32'(NUM_FREQ_POINTS * NUM_MEASUREMENTS));

    $display("[TB] RUN: core asleep in wfi for %0d cycles during the sweep", frozen_cycles);
    if (frozen_cycles == 0) begin
      $error("core never entered wfi sleep during the sweep");
      errors++;
    end

    // ---- park: FW_DONE set, the core must sleep, not spin -------------------
    begin
      int unsigned park_slept = 0;
      for (int unsigned k = 0; k < 2000; k++) begin
        @(posedge clk);
        if (core_sleep) park_slept++;
      end
      if (park_slept < 1900) begin
        $error("park loop is not sleeping: core_sleep high only %0d of 2000 cycles after FW_DONE",
               park_slept);
        errors++;
      end else begin
        $display("[TB] PARK: core_sleep high %0d of 2000 cycles after FW_DONE", park_slept);
      end
    end

    if (errors == 0) $display("[TB] %s_BOOT_E2E_PASS -- all checks passed", TAG);
    else             $display("[TB] %s_BOOT_E2E_FAIL -- %0d error(s)", TAG, errors);
    $finish;
  end

  // Watchdog well past the boot + 8M-cycle run budget.
  initial begin
    #(10 * 9_000_000);
    $error("watchdog"); $finish;
  end

endmodule
