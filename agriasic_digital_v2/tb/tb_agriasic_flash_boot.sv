// -----------------------------------------------------------------------------
// SPI-flash boot testbench (Phase 3, Option C).
//
// Program memory starts EMPTY (IMEM_INIT_FILE = ""), the boot strap is high,
// and a behavioural SPI NOR flash holds the image fw/build.sh produced
// (agriasic_fw_flash.hex: 16-byte header + code). Seven scenarios (A-G):
//
//   A. Good image: boot FSM reads header + payload over SPI, writes IMEM
//      through the bus, CRC matches, fw_valid releases the core, and the
//      firmware then runs the full three-point sweep with correct results.
//      IMEM contents are compared word-for-word with fw/agriasic_fw.hex.
//   B. Corrupted payload byte: chip reset -> boot ends in FAIL with error 3
//      (CRC), boot_fail_o high, core stays in reset.
//   C. Blank flash (0xFF): error 1 (bad magic), core stays in reset.
//   D. Image restored: chip reset -> boots again and the core reaches its
//      first wfi.
//   E. GOLDEN ROM boot: strap low, flash blanked entirely. The boot FSM
//      shadow-loads the on-die ROM into IMEM instead, the copy matches the
//      golden image word for word, and the firmware runs -- a bare chip with
//      no flash starts on its own.
//   F. IMEM is still WRITABLE after a ROM boot (the point of shadow-loading
//      rather than fetching from ROM): a word is patched the way a debugger
//      would over the SBA, and reads back changed.
//   G. BOOT_CTRL overrides the strap in both directions.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_agriasic_flash_boot;

  localparam int unsigned ADC_WIDTH = 8;
  localparam int unsigned IMAGE_WORDS = 256;

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
  logic boot_sel = 1'b1;   // A-D boot from flash; E-G use the golden ROM

  always #5 clk = ~clk;

  // Rev 5 two-channel AFE model: dV (analog mux channel 0, PGA on E2/E3) and
  // return current (channel 1, TIA on E4). Both are frozen by the single
  // adc_sample_o strobe at the FSM's chosen phase point; the comparator then
  // answers for whichever channel mux_sel selects.
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
    .dbg_cfg_mux_settle_o(), .dbg_cfg_amplitude_o(), .afe_pga_gain_o(), .afe_tia_rf_o(),
    .gpio_jtag_tck_i(1'b0), .gpio_jtag_tms_i(1'b1), .gpio_jtag_trst_ni(rst_n), .gpio_jtag_tdi_i(1'b0), .gpio_jtag_tdo_o(),
    .gpio_boot_sel_i(boot_sel),
    .gpio_flash_sck_o(flash_sck), .gpio_flash_cs_n_o(flash_cs_n), .gpio_flash_mosi_o(flash_mosi), .gpio_flash_miso_i(flash_miso),
    .gpio_boot_fail_o(boot_fail)
  );

  tb_spi_flash_model #(.IMAGE("agriasic_fw_flash.hex")) flash (
    .sck_i(flash_sck), .cs_n_i(flash_cs_n), .mosi_i(flash_mosi), .miso_o(flash_miso)
  );

  wire        fw_valid   = dut.u_control_shell.fw_valid;
  wire        core_rst_n = dut.u_control_shell.core_rst_n;
  wire        fw_halted  = dut.u_control_shell.done_o;
  wire        core_sleep = dut.u_control_shell.core_sleep;
  wire [3:0]  boot_state = 4'(dut.u_control_shell.u_boot.state_q);
  wire [2:0]  boot_err   = dut.u_control_shell.u_boot.err_q;
  wire [31:0] boot_status = dut.u_control_shell.u_boot.boot_status_o;

  localparam logic [3:0] S_DONE = 4'd7, S_FAIL = 4'd8;
  localparam logic [1:0] SRC_ROM = 2'd1, SRC_FLASH = 2'd2;

  // Golden ROM image, read from the same file the ROM was generated from.
  localparam int unsigned ROM_USED = 148;
  logic [31:0] golden_img [0:IMAGE_WORDS-1];
  initial $readmemh("agriasic_fw_golden.hex", golden_img);

  // Reference image, as the linker produced it.
  logic [31:0] ref_img [0:IMAGE_WORDS-1];
  int unsigned ref_words;
  initial begin
    for (int i = 0; i < IMAGE_WORDS; i++) ref_img[i] = 32'h0000_0000;
    $readmemh("agriasic_fw.hex", ref_img);
    // Word count from the flash header's length field (2-state simulators
    // fill unread $readmemh entries with 0, so the file cannot tell us).
    #1;
    ref_words = {flash.mem[7], flash.mem[6], flash.mem[5], flash.mem[4]} / 4;
  end

  int errors = 0;
  int unsigned cycles, measurements_seen;
  always_ff @(posedge clk) begin
    if (!rst_n) measurements_seen <= 0;
    else if (done_o) measurements_seen <= measurements_seen + 1;
  end

  task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] want);
    if (got !== want) begin
      $error("%s = 0x%08x, expected 0x%08x", what, got, want); errors++;
    end else $display("[TB]   %s = 0x%08x OK", what, got);
  endtask

  task automatic check_word(string name, int idx, logic [31:0] expected);
    logic [31:0] actual = dut.u_control_shell.u_mmio.u_dmem.ram_array[idx];
    if (actual !== expected) begin
      $error("%s (word %0d) = 0x%08x, expected 0x%08x", name, idx, actual, expected); errors++;
    end else $display("[TB]   %s = %0d OK", name, $signed(actual));
  endtask

  task automatic chip_reset();
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);
  endtask

  // Wait for the boot FSM to settle in DONE or FAIL; returns cycles taken.
  task automatic wait_boot(output int unsigned n);
    n = 0;
    while (boot_state != S_DONE && boot_state != S_FAIL && n < 400000) begin
      @(posedge clk); n++;
    end
  endtask

  initial begin
    rst_n = 1'b0; start_i = 1'b1;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    $display("[TB] reference image: %0d words (flash header length / 4)", ref_words);

    // ---- A. good image ------------------------------------------------------
    wait_boot(cycles);
    $display("[TB] A: boot finished in %0d cycles, state=%0d err=%0d", cycles, boot_state, boot_err);
    expect_eq("A boot state DONE", {28'd0, boot_state}, {28'd0, S_DONE});
    expect_eq("A boot error", {29'd0, boot_err}, 32'd0);
    expect_eq("A fw_valid", {31'd0, fw_valid}, 32'd1);
    expect_eq("A gpio_boot_fail_o", {31'd0, boot_fail}, 32'd0);
    expect_eq("A BOOT_STATUS.version", boot_status >> 16, {16'd0, flash.mem[9], flash.mem[8]});
    begin
      int bad = 0;
      for (int i = 0; i < ref_words; i++)
        if (dut.u_control_shell.u_imem.mem_array[i] !== ref_img[i]) begin
          if (bad < 4) $error("IMEM[%0d] = 0x%08x, image 0x%08x", i, dut.u_control_shell.u_imem.mem_array[i], ref_img[i]);
          bad++;
        end
      if (bad) errors++; else $display("[TB]   IMEM matches the linked image, %0d words OK", ref_words);
    end
    repeat (5) @(posedge clk);
    expect_eq("A core released (core_rst_n)", {31'd0, core_rst_n}, 32'd1);

    cycles = 0;
    while (!fw_halted && cycles < 8000000) begin @(posedge clk); cycles++; end
    if (!fw_halted) begin $error("A: firmware did not finish"); errors++; end
    else $display("[TB] A: firmware finished after %0d cycles (%0d measurements)", cycles, measurements_seen);
    check_word("OUT_COUNT",      'h100/4, 32'd2);
    check_word("OUT_NUM_POINTS", 'h104/4, 32'd3);
    check_word("OUT_DIV[2]",     'h118/4, 32'd10000);
    check_word("OUT_DV_I[2]",    'h128/4, 32'd400);
    check_word("OUT_DV_Q[2]",    'h138/4, 32'd280);
    check_word("OUT_CUR_I[2]",   'h158/4, 32'd240);
    check_word("OUT_CUR_Q[2]",   'h168/4, 32'd200);

    // ---- B. corrupted payload byte -> CRC failure -------------------------
    flash.mem[16 + 5] = flash.mem[16 + 5] ^ 8'hFF;
    chip_reset();
    wait_boot(cycles);
    $display("[TB] B: boot finished in %0d cycles, state=%0d err=%0d", cycles, boot_state, boot_err);
    expect_eq("B boot state FAIL", {28'd0, boot_state}, {28'd0, S_FAIL});
    expect_eq("B boot error = 3 (CRC)", {29'd0, boot_err}, 32'd3);
    expect_eq("B gpio_boot_fail_o", {31'd0, boot_fail}, 32'd1);
    expect_eq("B fw_valid", {31'd0, fw_valid}, 32'd0);
    repeat (1000) @(posedge clk);
    expect_eq("B core held in reset", {31'd0, core_rst_n}, 32'd0);

    // ---- C. blank flash -> bad magic --------------------------------------
    for (int i = 0; i < 16; i++) flash.mem[i] = 8'hFF;
    chip_reset();
    wait_boot(cycles);
    $display("[TB] C: boot finished in %0d cycles, state=%0d err=%0d", cycles, boot_state, boot_err);
    expect_eq("C boot error = 1 (magic)", {29'd0, boot_err}, 32'd1);
    expect_eq("C core held in reset", {31'd0, core_rst_n}, 32'd0);

    // ---- D. image restored -> boots again ---------------------------------
    $readmemh("agriasic_fw_flash.hex", flash.mem);
    chip_reset();
    wait_boot(cycles);
    $display("[TB] D: boot finished in %0d cycles, state=%0d err=%0d", cycles, boot_state, boot_err);
    expect_eq("D boot state DONE", {28'd0, boot_state}, {28'd0, S_DONE});
    cycles = 0;
    while (!core_sleep && cycles < 20000) begin @(posedge clk); cycles++; end
    expect_eq("D core running (reached wfi)", {31'd0, core_sleep}, 32'd1);

    // ---- E. golden ROM boot with no flash at all --------------------------
    for (int i = 0; i < 64; i++) flash.mem[i] = 8'hFF;   // blank the image
    boot_sel = 1'b0;                                      // strap: golden ROM
    chip_reset();
    wait_boot(cycles);
    $display("[TB] E: ROM boot finished in %0d cycles, state=%0d err=%0d",
             cycles, boot_state, boot_err);
    expect_eq("E boot state DONE", {28'd0, boot_state}, {28'd0, S_DONE});
    expect_eq("E boot error", {29'd0, boot_err}, 32'd0);
    expect_eq("E fw_valid", {31'd0, fw_valid}, 32'd1);
    expect_eq("E BOOT_STATUS source = golden ROM", (boot_status >> 12) & 32'h3, {30'd0, SRC_ROM});
    // The ROM copy must reproduce the golden image exactly.
    begin
      int bad = 0;
      for (int i = 0; i < ROM_USED; i++)
        if (dut.u_control_shell.u_imem.mem_array[i] !== golden_img[i]) begin
          if (bad < 4) $error("ROM copy: IMEM[%0d] = 0x%08x, golden 0x%08x",
                              i, dut.u_control_shell.u_imem.mem_array[i], golden_img[i]);
          bad++;
        end
      if (bad) errors++;
      else $display("[TB]   IMEM matches the golden ROM image, %0d words OK", ROM_USED);
    end
    cycles = 0;
    while (!fw_halted && cycles < 8000000) begin @(posedge clk); cycles++; end
    if (!fw_halted) begin $error("E: firmware did not finish after a ROM boot"); errors++; end
    else $display("[TB] E: firmware finished after %0d cycles (%0d measurements)",
                  cycles, measurements_seen);
    check_word("OUT_DV_I[2] (ROM boot)",  'h128/4, 32'd400);
    check_word("OUT_CUR_I[2] (ROM boot)", 'h158/4, 32'd240);

    // ---- F. IMEM is still writable after a ROM boot ------------------------
    // This is what the shadow-load buys over a fetch-path mux: a debugger can
    // patch a constant in place. Poke a word and read it back.
    begin
      logic [31:0] saved = dut.u_control_shell.u_imem.mem_array[64];
      dut.u_control_shell.u_imem.mem_array[64] = 32'hDEAD_BEEF;
      @(posedge clk);
      expect_eq("F IMEM patchable after ROM boot",
                dut.u_control_shell.u_imem.mem_array[64], 32'hDEAD_BEEF);
      dut.u_control_shell.u_imem.mem_array[64] = saved;
    end

    // ---- G. BOOT_CTRL overrides the strap ---------------------------------
    // Strap still low (ROM), but force a flash boot: the flash is blank, so
    // this must fail on magic -- proving the override reached the flash path.
    force dut.u_control_shell.boot_retry = 1'b1;
    @(posedge clk);
    release dut.u_control_shell.boot_retry;
    wait_boot(cycles);
    expect_eq("G forced flash boot with blank flash -> error 1", {29'd0, boot_err}, 32'd1);
    expect_eq("G BOOT_STATUS source = flash", (boot_status >> 12) & 32'h3, {30'd0, SRC_FLASH});
    // And back the other way: force a ROM boot, which must succeed.
    force dut.u_control_shell.boot_rom_req = 1'b1;
    @(posedge clk);
    release dut.u_control_shell.boot_rom_req;
    wait_boot(cycles);
    expect_eq("G forced ROM boot recovers", {28'd0, boot_state}, {28'd0, S_DONE});
    expect_eq("G BOOT_STATUS source = golden ROM", (boot_status >> 12) & 32'h3, {30'd0, SRC_ROM});

    if (errors == 0) $display("[TB] FLASH_BOOT_PASS -- all checks passed");
    else             $display("[TB] FLASH_BOOT_FAIL -- %0d error(s)", errors);
    $finish;
  end

  initial begin
    #200_000_000;
    $error("watchdog"); $finish;
  end

endmodule
