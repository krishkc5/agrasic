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
//   E. Once firmware finishes, the host reads a REAL measurement result out of
//      DMEM -- the capability GAP-11 was about.
//
// SPI timing follows the proven pattern in tb_agriasic_digital_spi_top: mode 0,
// MSB first, one bit per 240 ns against a 10 ns core clock, which is well
// inside the f_clk/16 ceiling spi_slave's oversampling imposes.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_agriasic_spi_host;

  localparam int unsigned ADC_WIDTH = 8;
  localparam logic [31:0] DMEM_BASE = 32'h0001_0000;

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
    .afe_pga_gain_o (), .afe_tia_rf_o (),
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
  logic [7:0]  st;
  int unsigned waited;

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
    host_write32(DMEM_BASE + 32'h080, 32'hDEAD_BEEF);
    host_read32 (DMEM_BASE + 32'h080, v);
    expect_eq("A: DMEM read-back (core running)", v, 32'hDEAD_BEEF);
    expect_eq("A: ram_array[0x20] (hier)",
              dut.u_control_shell.u_mmio.u_dmem.ram_array[32'h20], 32'hDEAD_BEEF);

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
    host_read32(DMEM_BASE + 32'h080, v);
    expect_eq("D: DMEM intact after refusals", v, 32'hDEAD_BEEF);

    // ---- E. read a real result once the sweep finishes ----------------------
    waited = 0;
    while (!fw_halted && waited < 4_000_000) begin
      @(posedge clk); waited++;
    end
    if (!fw_halted) begin
      $error("firmware did not finish within %0d cycles", waited); errors++;
    end else begin
      $display("[TB]   E: firmware finished after %0d cycles", waited);
      host_read32(DMEM_BASE + 32'h100, v);
      expect_eq("E: OUT_COUNT read over SPI", v, 32'd2);
      host_read32(DMEM_BASE + 32'h104, v);
      expect_eq("E: OUT_NUM_POINTS read over SPI", v, 32'd3);
      host_read32(DMEM_BASE + 32'h120, v);
      expect_eq("E: OUT_DV_I[0] read over SPI", v, 32'd400);
      host_read32(DMEM_BASE + 32'h150, v);
      expect_eq("E: OUT_CUR_I[0] read over SPI", v, 32'd240);
    end

    if (errors == 0) $display("[TB] SPI_HOST_PASS -- all checks passed");
    else             $display("[TB] SPI_HOST_FAIL -- %0d error(s)", errors);
    $finish;
  end

  initial begin
    #40_000_000;
    $error("tb_agriasic_spi_host: global timeout");
    $finish;
  end

endmodule
