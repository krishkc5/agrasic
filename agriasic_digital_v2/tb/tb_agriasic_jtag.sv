// -----------------------------------------------------------------------------
// JTAG / RISC-V debug module testbench (Phase 2).
//
// Drives the chip's five JTAG pins with a behavioural IEEE 1149.1 master and
// speaks the RISC-V Debug Transport Module protocol (riscv-dbg dmi_jtag) to
// the Debug Module (dm_top), the way OpenOCD would. The real firmware runs
// underneath, so the halt lands inside a live measurement sweep.
//
// What is checked, in order:
//   1. TAP: IDCODE reads back the value programmed in the shell; DTMCS
//      reports abits=7 and DTM version 1 (Debug Spec 0.13).
//   2. DM: dmcontrol.dmactive; dmstatus.version=2, authenticated.
//   3. Halt: haltreq while the core is asleep in wfi (measurement in flight)
//      -> dmstatus.allhalted; Ibex's debug_mode observed.
//   4. Abstract commands: read dpc (inside the firmware image) and sp
//      (inside the relocated RAM) through data0 -- this exercises the debug
//      ROM / program buffer path on the INSTRUCTION side of the bus and
//      data0 on the DATA side.
//   5. System bus access: write/read RAM at 0x0001_0400, write/read the
//      last IMEM word (the loader path OpenOCD `load` uses), read an MMIO
//      register, and provoke sberror on an unmapped address.
//   6. Resume: resumereq -> allresumeack, and the firmware then completes the
//      sweep with correct results, read back BOTH through the hierarchy and
//      through the debugger's system bus.
//   7. ndmreset: core + peripheral bridge reset, DM survives, havereset
//      handshake acknowledged.
//   8. Boot control over the SBA (Phase 3): BOOT_CTRL.retry with no flash
//      attached -> boot FAIL (bad magic), boot_fail_o, core held and reported
//      unavailable; BOOT_CTRL.release -> core runs again. This is the bench
//      flow: load IMEM over JTAG, then release.
//
// TCK is a quarter of the core clock; each DMI transaction is followed by
// idle TCK cycles so the DTM's clock-domain crossing completes before the
// response is scanned out (a busy response is retried after dmireset, as
// OpenOCD does).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_agriasic_jtag;

  localparam int unsigned ADC_WIDTH = 8;
  localparam int unsigned TCK_HALF  = 20;           // TCK = 40 ns, clk = 10 ns

  // Shell constants mirrored here (checked against the DUT where possible).
  localparam logic [31:0] EXP_IDCODE = 32'h1434_1001;
  localparam logic [31:0] DMEM_BASE  = 32'h0001_0000;
  localparam logic [31:0] DM_BASE    = 32'h1A11_0000;

  // DTM instruction register
  localparam logic [4:0] IR_IDCODE = 5'h01;
  localparam logic [4:0] IR_DTMCS  = 5'h10;
  localparam logic [4:0] IR_DMI    = 5'h11;

  // DM registers (Debug Spec 0.13)
  localparam logic [6:0] DM_DATA0      = 7'h04;
  localparam logic [6:0] DM_DMCONTROL  = 7'h10;
  localparam logic [6:0] DM_DMSTATUS   = 7'h11;
  localparam logic [6:0] DM_ABSTRACTCS = 7'h16;
  localparam logic [6:0] DM_COMMAND    = 7'h17;
  localparam logic [6:0] DM_SBCS       = 7'h38;
  localparam logic [6:0] DM_SBADDRESS0 = 7'h39;
  localparam logic [6:0] DM_SBDATA0    = 7'h3C;

  localparam logic [31:0] DMCONTROL_DMACTIVE     = 32'h0000_0001;
  localparam logic [31:0] DMCONTROL_NDMRESET     = 32'h0000_0002;
  localparam logic [31:0] DMCONTROL_ACKHAVERESET = 32'h1000_0000;
  localparam logic [31:0] DMCONTROL_RESUMEREQ    = 32'h4000_0000;
  localparam logic [31:0] DMCONTROL_HALTREQ      = 32'h8000_0000;

  localparam logic [31:0] SBCS_SBACCESS32  = 32'h0004_0000;  // sbaccess = 2
  localparam logic [31:0] SBCS_SBREADONADDR = 32'h0010_0000;
  localparam logic [31:0] SBCS_SBERROR_MASK = 32'h0000_7000;
  localparam logic [31:0] SBCS_SBBUSY       = 32'h0020_0000;

  // ---------------------------------------------------------------------------
  // DUT and measurement-engine model (same as tb_agriasic_rv32i_e2e)
  // ---------------------------------------------------------------------------
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

  logic jtag_tck = 1'b0, jtag_tms = 1'b1, jtag_trst_n = 1'b0, jtag_tdi = 1'b0;
  logic jtag_tdo;

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


  logic boot_fail;

  agriasic_digital_rv32i_top #(
    .ADC_WIDTH         (ADC_WIDTH),
    .BOOT_DELAY_CYCLES (64),
    .IMEM_PRELOADED    (1'b1)       // IMEM from $readmemh; boot strap low
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
    .gpio_jtag_tck_i(jtag_tck), .gpio_jtag_tms_i(jtag_tms), .gpio_jtag_trst_ni(jtag_trst_n),
    .gpio_jtag_tdi_i(jtag_tdi), .gpio_jtag_tdo_o(jtag_tdo),
    .gpio_boot_sel_i(1'b0),
    .gpio_flash_sck_o(), .gpio_flash_cs_n_o(), .gpio_flash_mosi_o(), .gpio_flash_miso_i(1'b0),   // no flash on this bench
    .gpio_boot_fail_o(boot_fail)
  );

  wire fw_halted  = dut.u_control_shell.done_o;
  wire dbg_mode   = dut.u_control_shell.u_core.u_ibex_core.id_stage_i.controller_i.debug_mode_q;
  wire core_sleep = dut.u_control_shell.core_sleep;

  int errors = 0;
  int unsigned measurements_seen;
  always_ff @(posedge clk) begin
    if (!rst_n) measurements_seen <= 0;
    else if (done_o) measurements_seen <= measurements_seen + 1;
  end

  // ---------------------------------------------------------------------------
  // JTAG master
  // ---------------------------------------------------------------------------
  task automatic jtag_bit(input logic tms, input logic tdi, output logic tdo);
    jtag_tms = tms;
    jtag_tdi = tdi;
    #(TCK_HALF);
    tdo = jtag_tdo;          // TDO was launched on the previous falling edge
    jtag_tck = 1'b1;
    #(TCK_HALF);
    jtag_tck = 1'b0;
  endtask

  task automatic jtag_idle(input int n);
    logic d;
    repeat (n) jtag_bit(1'b0, 1'b0, d);
  endtask

  task automatic jtag_tap_reset();
    logic d;
    jtag_trst_n = 1'b0;
    #(4*TCK_HALF);
    jtag_trst_n = 1'b1;
    repeat (6) jtag_bit(1'b1, 1'b0, d);  // Test-Logic-Reset
    jtag_bit(1'b0, 1'b0, d);             // -> Run-Test/Idle
  endtask

  // From Run-Test/Idle, shift an IR value, return to Run-Test/Idle.
  task automatic jtag_shift_ir(input logic [4:0] ir);
    logic d;
    jtag_bit(1'b1, 1'b0, d);   // Select-DR
    jtag_bit(1'b1, 1'b0, d);   // Select-IR
    jtag_bit(1'b0, 1'b0, d);   // Capture-IR
    jtag_bit(1'b0, 1'b0, d);   // Shift-IR
    for (int i = 0; i < 5; i++) jtag_bit((i == 4), ir[i], d);  // last bit -> Exit1-IR
    jtag_bit(1'b1, 1'b0, d);   // Update-IR
    jtag_bit(1'b0, 1'b0, d);   // Run-Test/Idle
  endtask

  // From Run-Test/Idle, shift n bits through DR (LSB first), return to RTI.
  task automatic jtag_shift_dr(input int n, input logic [63:0] din, output logic [63:0] dout);
    logic d;
    dout = '0;
    jtag_bit(1'b1, 1'b0, d);   // Select-DR
    jtag_bit(1'b0, 1'b0, d);   // Capture-DR
    jtag_bit(1'b0, 1'b0, d);   // Shift-DR
    for (int i = 0; i < n; i++) begin
      jtag_bit((i == n-1), din[i], d);
      dout[i] = d;
    end
    jtag_bit(1'b1, 1'b0, d);   // Update-DR
    jtag_bit(1'b0, 1'b0, d);   // Run-Test/Idle
  endtask

  // ---------------------------------------------------------------------------
  // DTM / DMI layer
  // ---------------------------------------------------------------------------
  task automatic dtmcs_dmireset();
    logic [63:0] r;
    jtag_shift_ir(IR_DTMCS);
    jtag_shift_dr(32, 64'h0001_0000, r);   // dmireset
    jtag_shift_ir(IR_DMI);
  endtask

  // One DMI scan: {addr[6:0], data[31:0], op[1:0]} = 41 bits. Returns the
  // response to the PREVIOUS transaction.
  task automatic dmi_scan(input logic [6:0] addr, input logic [31:0] data, input logic [1:0] op,
                          output logic [31:0] rdata, output logic [1:0] resp);
    logic [63:0] r;
    jtag_shift_dr(41, {23'd0, addr, data, op}, r);
    resp  = r[1:0];
    rdata = r[33:2];
  endtask

  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] data);
    logic [31:0] rd; logic [1:0] resp;
    for (int attempt = 0; attempt < 8; attempt++) begin
      dmi_scan(addr, data, 2'd2, rd, resp);
      jtag_idle(8);
      dmi_scan(7'd0, 32'd0, 2'd0, rd, resp);   // NOP to fetch the write's response
      if (resp == 2'd0) return;
      dtmcs_dmireset();                        // busy: clear and retry
      jtag_idle(8);
    end
    $error("dmi_write(0x%02x) never succeeded", addr);
    errors++;
  endtask

  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] data);
    logic [31:0] rd; logic [1:0] resp;
    for (int attempt = 0; attempt < 8; attempt++) begin
      dmi_scan(addr, 32'd0, 2'd1, rd, resp);
      jtag_idle(8);
      dmi_scan(7'd0, 32'd0, 2'd0, rd, resp);
      if (resp == 2'd0) begin data = rd; return; end
      dtmcs_dmireset();
      jtag_idle(8);
    end
    $error("dmi_read(0x%02x) never succeeded", addr);
    errors++;
    data = 32'hDEAD_DEAD;
  endtask

  // ---------------------------------------------------------------------------
  // DM helpers
  // ---------------------------------------------------------------------------
  task automatic dm_poll(input logic [6:0] addr, input logic [31:0] mask, input logic [31:0] want,
                         input string what);
    logic [31:0] v;
    for (int i = 0; i < 200; i++) begin
      dmi_read(addr, v);
      if ((v & mask) == want) return;
    end
    $error("timeout waiting for %s (last 0x%08x)", what, v);
    errors++;
  endtask

  // Abstract command: access register, 32-bit, transfer, read.
  task automatic dm_read_reg(input logic [15:0] regno, output logic [31:0] value);
    logic [31:0] cs;
    dmi_write(DM_COMMAND, {8'h00, 1'b0, 3'd2, 1'b0, 1'b0, 1'b1, 1'b0, regno});
    dm_poll(DM_ABSTRACTCS, 32'h0000_1000, 32'h0, "abstractcs.busy clear");
    dmi_read(DM_ABSTRACTCS, cs);
    if (cs[10:8] != 3'd0) begin
      $error("abstract command regno 0x%04x: cmderr=%0d", regno, cs[10:8]);
      errors++;
      dmi_write(DM_ABSTRACTCS, 32'h0000_0700);   // clear cmderr (W1C)
    end
    dmi_read(DM_DATA0, value);
  endtask

  task automatic sba_write32(input logic [31:0] addr, input logic [31:0] data);
    dmi_write(DM_SBCS, SBCS_SBACCESS32);
    dmi_write(DM_SBADDRESS0, addr);
    dmi_write(DM_SBDATA0, data);
    dm_poll(DM_SBCS, SBCS_SBBUSY, 32'h0, "sbbusy clear after write");
  endtask

  task automatic sba_read32(input logic [31:0] addr, output logic [31:0] data, output logic [2:0] sberror);
    logic [31:0] cs;
    dmi_write(DM_SBCS, SBCS_SBACCESS32 | SBCS_SBREADONADDR);
    dmi_write(DM_SBADDRESS0, addr);          // triggers the read
    dm_poll(DM_SBCS, SBCS_SBBUSY, 32'h0, "sbbusy clear after read");
    dmi_read(DM_SBDATA0, data);
    dmi_read(DM_SBCS, cs);
    sberror = cs[14:12];
    if (sberror != 3'd0) dmi_write(DM_SBCS, SBCS_SBACCESS32 | SBCS_SBERROR_MASK);  // W1C
  endtask

  task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] want);
    if (got !== want) begin
      $error("%s = 0x%08x, expected 0x%08x", what, got, want);
      errors++;
    end else begin
      $display("[TB]   %s = 0x%08x OK", what, got);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  logic [63:0] dr;
  logic [31:0] v, dpc, sp;
  logic [2:0]  sberr;
  int unsigned cycles;

  initial begin
    // Same 1->0->1 reset preamble as the e2e TB (Ibex's gated-clock async
    // resets need a real negedge under Verilator).
    rst_n = 1'b1; start_i = 1'b1;
    repeat (12) @(posedge clk);
    rst_n = 1'b0; start_i = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    start_i = 1'b1;
    $display("[TB] start asserted, firmware running");

    // Let the firmware reach its first wfi (first measurement in flight).
    while (!core_sleep) @(posedge clk);
    repeat (20) @(posedge clk);
    $display("[TB] core asleep in wfi, attaching debugger");

    // ---- 1. TAP -----------------------------------------------------------
    jtag_tap_reset();
    jtag_shift_ir(IR_IDCODE);
    jtag_shift_dr(32, 64'd0, dr);
    expect_eq("IDCODE", dr[31:0], EXP_IDCODE);

    jtag_shift_ir(IR_DTMCS);
    jtag_shift_dr(32, 64'd0, dr);
    expect_eq("dtmcs.abits", {26'd0, dr[9:4]}, 32'd7);
    expect_eq("dtmcs.version", {28'd0, dr[3:0]}, 32'd1);

    // ---- 2. DM activation -------------------------------------------------
    jtag_shift_ir(IR_DMI);
    dmi_write(DM_DMCONTROL, DMCONTROL_DMACTIVE);
    dmi_read(DM_DMCONTROL, v);
    expect_eq("dmcontrol.dmactive", v & 32'h1, 32'h1);
    dmi_read(DM_DMSTATUS, v);
    expect_eq("dmstatus.version", v & 32'hF, 32'h2);
    expect_eq("dmstatus.authenticated", (v >> 7) & 32'h1, 32'h1);
    expect_eq("dmstatus.allrunning", (v >> 11) & 32'h1, 32'h1);

    // ---- 3. Halt ----------------------------------------------------------
    dmi_write(DM_DMCONTROL, DMCONTROL_HALTREQ | DMCONTROL_DMACTIVE);
    dm_poll(DM_DMSTATUS, 32'h0000_0200, 32'h0000_0200, "dmstatus.allhalted");
    dmi_write(DM_DMCONTROL, DMCONTROL_DMACTIVE);   // drop haltreq
    expect_eq("ibex debug_mode", {31'd0, dbg_mode}, 32'd1);
    $display("[TB] hart halted (was asleep in wfi at the time)");

    // ---- 4. Abstract register reads ---------------------------------------
    dm_read_reg(16'h07b1, dpc);                    // dpc
    if (dpc < 32'h80 || dpc >= 32'h1000) begin
      $error("dpc 0x%08x outside the firmware image", dpc); errors++;
    end else $display("[TB]   dpc = 0x%08x (inside IMEM) OK", dpc);
    dm_read_reg(16'h1002, sp);                     // x2 = sp
    if (sp < DMEM_BASE || sp > DMEM_BASE + 32'h800) begin
      $error("sp 0x%08x outside the relocated RAM", sp); errors++;
    end else $display("[TB]   sp  = 0x%08x (inside DMEM @0x10000) OK", sp);

    // ---- 5. System bus access ---------------------------------------------
    // DMEM is 512 B: 0x000-0x1FF. Results occupy 0x100-0x16B and the stack the
    // top 32 B, so 0x080 is the scratch hole both leave free.
    sba_write32(DMEM_BASE + 32'h080, 32'hA5A5_1234);
    expect_eq("ram_array[0x20] after SBA write",
              dut.u_control_shell.u_mmio.u_dmem.ram_array[32'h20], 32'hA5A5_1234);
    sba_read32(DMEM_BASE + 32'h080, v, sberr);
    expect_eq("SBA read-back RAM", v, 32'hA5A5_1234);
    expect_eq("sberror (RAM)", {29'd0, sberr}, 32'd0);

    sba_write32(32'h0000_03FC, 32'h0000_0013);      // NOP into the last IMEM word
    expect_eq("imem mem_array[255] after SBA write",
              dut.u_control_shell.u_imem.mem_array[255], 32'h0000_0013);
    sba_read32(32'h0000_03FC, v, sberr);
    expect_eq("SBA read-back IMEM", v, 32'h0000_0013);
    expect_eq("sberror (IMEM)", {29'd0, sberr}, 32'd0);

    sba_read32(32'h8000_0014, v, sberr);            // STATUS
    expect_eq("sberror (MMIO STATUS)", {29'd0, sberr}, 32'd0);
    $display("[TB]   STATUS via SBA = 0x%08x", v);

    sba_read32(32'h2000_0000, v, sberr);            // unmapped
    if (sberr == 3'd0) begin
      $error("SBA read of unmapped 0x20000000 did not set sberror"); errors++;
    end else $display("[TB]   unmapped SBA read -> sberror=%0d OK", sberr);

    // ---- 6. Resume and let the sweep finish -------------------------------
    dmi_write(DM_DMCONTROL, DMCONTROL_RESUMEREQ | DMCONTROL_DMACTIVE);
    dm_poll(DM_DMSTATUS, 32'h0002_0000, 32'h0002_0000, "dmstatus.allresumeack");
    dmi_write(DM_DMCONTROL, DMCONTROL_DMACTIVE);
    expect_eq("ibex debug_mode after resume", {31'd0, dbg_mode}, 32'd0);
    $display("[TB] hart resumed");

    cycles = 0;
    while (!fw_halted && cycles < 8000000) begin
      @(posedge clk);
      cycles++;
    end
    if (!fw_halted) begin
      $error("TIMEOUT: firmware did not finish after resume"); errors++;
    end else $display("[TB] firmware finished after %0d cycles (%0d measurements)", cycles, measurements_seen);

    // Results via the hierarchy ...
    expect_eq("OUT_COUNT (hier)", dut.u_control_shell.u_mmio.u_dmem.ram_array[32'h40], 32'd2);
    expect_eq("OUT_I[2]  (hier)", dut.u_control_shell.u_mmio.u_dmem.ram_array[32'h4A], 32'd400);
    expect_eq("OUT_Q[2]  (hier)", dut.u_control_shell.u_mmio.u_dmem.ram_array[32'h4E], 32'd280);
    // ... and through the debugger, at the flat-map addresses.
    sba_read32(DMEM_BASE + 32'h100, v, sberr); expect_eq("OUT_COUNT (SBA)", v, 32'd2);
    sba_read32(DMEM_BASE + 32'h104, v, sberr); expect_eq("OUT_NUM_POINTS (SBA)", v, 32'd3);
    sba_read32(DMEM_BASE + 32'h128, v, sberr); expect_eq("OUT_I[2] (SBA)", v, 32'd400);
    sba_read32(DMEM_BASE + 32'h138, v, sberr); expect_eq("OUT_Q[2] (SBA)", v, 32'd280);
    sba_read32(DMEM_BASE + 32'h140, v, sberr); expect_eq("OUT_TEMP (SBA)", v, 32'hFFFF_FFFF);

    // ---- 7. ndmreset ------------------------------------------------------
    dmi_write(DM_DMCONTROL, DMCONTROL_NDMRESET | DMCONTROL_DMACTIVE);
    repeat (4) @(posedge clk);
    expect_eq("sys_rst_n during ndmreset", {31'd0, dut.u_control_shell.sys_rst_n}, 32'd0);
    expect_eq("FW_DONE cleared by ndmreset", {31'd0, dut.u_control_shell.done_o}, 32'd0);
    dmi_write(DM_DMCONTROL, DMCONTROL_DMACTIVE);   // release
    dmi_read(DM_DMSTATUS, v);
    expect_eq("dmstatus.allhavereset", (v >> 19) & 32'h1, 32'h1);
    dmi_write(DM_DMCONTROL, DMCONTROL_ACKHAVERESET | DMCONTROL_DMACTIVE);
    dmi_read(DM_DMSTATUS, v);
    expect_eq("dmstatus.allhavereset after ack", (v >> 19) & 32'h1, 32'h0);
    expect_eq("dmstatus.allrunning after ndmreset", (v >> 11) & 32'h1, 32'h1);
    // The firmware restarted from 0x80 (start_i is still high): it must reach
    // its first wfi again, proving the core came out of ndmreset cleanly.
    cycles = 0;
    while (!core_sleep && cycles < 5000) begin @(posedge clk); cycles++; end
    expect_eq("core back asleep after ndmreset restart", {31'd0, core_sleep}, 32'd1);

    // ---- 8. Boot control over the SBA (Phase 3) ---------------------------
    // retry with nothing on the flash pins: header reads as 0 -> bad magic.
    sba_write32(32'h8000_0024, 32'h0000_0002);           // BOOT_CTRL.retry
    for (int i = 0; i < 400; i++) begin                  // ~2.7k core cycles
      sba_read32(32'h8000_0020, v, sberr);               // BOOT_STATUS
      if (v[3:0] == 4'd8) break;
    end
    expect_eq("BOOT_STATUS.state = FAIL", {28'd0, v[3:0]}, 32'd8);
    expect_eq("BOOT_STATUS.error = 1 (magic)", {29'd0, v[6:4]}, 32'd1);
    expect_eq("BOOT_STATUS.fw_valid", {31'd0, v[8]}, 32'd0);
    expect_eq("gpio_boot_fail_o pin", {31'd0, boot_fail}, 32'd1);
    dmi_read(DM_DMSTATUS, v);
    expect_eq("dmstatus.allunavail (core held)", (v >> 13) & 32'h1, 32'h1);
    // bench flow: IMEM is already loaded (SBA writes tested above); release.
    sba_write32(32'h8000_0024, 32'h0000_0001);           // BOOT_CTRL.release
    sba_read32(32'h8000_0020, v, sberr);
    expect_eq("BOOT_STATUS.fw_valid after release", {31'd0, v[8]}, 32'd1);
    dmi_read(DM_DMSTATUS, v);
    expect_eq("dmstatus.allrunning after release", (v >> 11) & 32'h1, 32'h1);
    cycles = 0;
    while (!core_sleep && cycles < 20000) begin @(posedge clk); cycles++; end
    expect_eq("core reached wfi after release", {31'd0, core_sleep}, 32'd1);
    // SPI peripheral ownership handed to firmware once the boot FSM is idle.
    sba_read32(32'h8000_0030, v, sberr);                 // SPI_STATUS
    expect_eq("SPI_STATUS.fw_owned", {31'd0, v[1]}, 32'd1);

    if (errors == 0) $display("[TB] JTAG_DEBUG_PASS -- all checks passed");
    else             $display("[TB] JTAG_DEBUG_FAIL -- %0d error(s)", errors);
    $finish;
  end

  // Global watchdog.
  initial begin
    #200_000_000;
    $error("watchdog: testbench did not finish");
    $finish;
  end

endmodule
