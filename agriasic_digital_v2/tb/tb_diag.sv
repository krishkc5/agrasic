`timescale 1ns / 1ns
module tb_diag;
  logic clk = 1'b0;
  logic rst_n, start_i;
  logic conv_start_o, busy_o, done_o;
  logic [7:0] sine_code_o;
  logic [1:0] mux_sel_o;
  logic adc_enable_o, adc_sample_o;
  logic [7:0] adc_dac_o;
  logic adc_comp_i;
  logic signed [15:0] result_dv_i_o, result_dv_q_o, result_cur_i_o, result_cur_q_o;
  logic [3:0] cfg_pair_log2_o;
  logic [7:0] cfg_settle_cycles_o;
  logic [13:0] cfg_exc_divider_o;  // Rev 4.3 Phase 4.2 width; was left at [7:0] here, fixed
  logic [7:0] cfg_conv_cycles_o;

  always #5 clk = ~clk;

  // Behavioral comparator model -- see sar_controller's header for the
  // adc_comp_i convention this implements.
  // Rev 4.3 Phase 5: four distinct targets keyed on measurement_fsm's own
  // state -- see tb_agriasic_digital_top's header comment on this model for
  // why phase_index itself can't be used directly (one-cycle sample-accept
  // lag inside sar_controller at small divider values).
  //   3=S_SAMPLE_0 5=S_SAMPLE_180 8=S_SAMPLE_90 10=S_SAMPLE_270
  logic [7:0] adc_target_held_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (4'(dut.u_measurement_top.u_measurement_fsm.state_q))
        4'd3:  adc_target_held_q <= 8'd200;  // D(0)
        4'd8:  adc_target_held_q <= 8'd150;  // D(90)
        4'd5:  adc_target_held_q <= 8'd100;  // D(180)
        4'd10: adc_target_held_q <= 8'd80;   // D(270)
        default: begin end
      endcase
    end
  end
  assign adc_comp_i = (adc_target_held_q >= adc_dac_o);

  agriasic_digital_rv32i_top #(.BOOT_DELAY_CYCLES(64), .IMEM_PRELOADED(1'b1)) dut (
    .clk(clk), .rst_n(rst_n), .gpio_start_i(start_i),
    .afe_conv_start_o(conv_start_o), .afe_sine_code_o(sine_code_o), .afe_mux_sel_o(mux_sel_o),
    .afe_adc_enable_o(adc_enable_o), .afe_sample_o(adc_sample_o),
    .afe_adc_dac_o(adc_dac_o), .afe_adc_comp_i(adc_comp_i),
    .dbg_busy_o(busy_o), .dbg_done_o(done_o),
    .dbg_result_dv_i_o(result_dv_i_o), .dbg_result_dv_q_o(result_dv_q_o),
    .dbg_result_cur_i_o(result_cur_i_o), .dbg_result_cur_q_o(result_cur_q_o),
    .dbg_cfg_mux_settle_o(), .dbg_cfg_amplitude_o(), .afe_tia_rf_o(),
    .gpio_spi_sclk_i(1'b0), .gpio_spi_cs_n_i(1'b1), .gpio_spi_mosi_i(1'b0),
    .gpio_spi_miso_o(), .gpio_spi_miso_oe_o(),
    .dbg_cfg_pair_log2_o(cfg_pair_log2_o), .dbg_cfg_settle_cycles_o(cfg_settle_cycles_o),
    .dbg_cfg_exc_divider_o(cfg_exc_divider_o), .dbg_cfg_conv_cycles_o(cfg_conv_cycles_o),
    .gpio_jtag_tck_i(1'b0), .gpio_jtag_tms_i(1'b1), .gpio_jtag_trst_ni(rst_n), .gpio_jtag_tdi_i(1'b0), .gpio_jtag_tdo_o(),
    .gpio_boot_sel_i(1'b0), .gpio_flash_sck_o(), .gpio_flash_cs_n_o(), .gpio_flash_mosi_o(), .gpio_flash_miso_i(1'b0), .gpio_boot_fail_o());

  wire [31:0] pc = dut.u_control_shell.instr_addr;
  wire halted = dut.u_control_shell.done_o;
  wire mb = dut.u_control_shell.u_mmio.meas_busy_q;
  wire md = dut.u_control_shell.u_mmio.meas_done_q;

  int unsigned meas_count;
  always_ff @(posedge clk) if (!rst_n) meas_count <= 0; else if (done_o) meas_count <= meas_count + 1;

  int unsigned halt_seen;
  int unsigned maxpc;

  initial begin
    halt_seen = 0; maxpc = 0;
    rst_n = 1; start_i = 1; repeat (12) @(posedge clk); rst_n = 0; start_i = 0;  // 1->0->1 on the core reset: Ibex async resets need a negedge under Verilator
    repeat (10) @(posedge clk);
    rst_n = 1; repeat (3) @(posedge clk);
    start_i = 1;

    // Rev 4.3 Phase 7: the sweep includes the real N=10000 (1 kHz) point,
    // whose settle alone is 2 periods x 16 x 10000 = 320,000 cycles -- the
    // full sweep measured ~3.15M cycles in tb_agriasic_rv32i_e2e.sv, so this
    // loop bound and the print interval both need to scale accordingly
    // (printing every 200 cycles across 3M+ cycles would flood the log).
    for (int c = 0; c < 3500000; c++) begin
      @(posedge clk);
      if (halted) halt_seen++;
      if (pc > maxpc) maxpc = pc;
      if (c % 200000 == 0)
        $display("c%0d pc=%02x meas=%0d mmio_busy=%b mmio_done=%b halted=%b",
                 c, pc, meas_count, mb, md, halted);
      if (halted) break;
    end

    $display("=== summary ===");
    $display("measurements completed : %0d", meas_count);
    $display("max PC reached         : 0x%02x", maxpc);
    $display("halt asserted (cycles) : %0d", halt_seen);
    $display("scratch RAM (8-point sweep layout -- see the map in fw.c):");
    $display("  [0x000] count (per point)  = %0d", $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[0]));
    $display("  [0x004] num_points         = %0d", $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[1]));
    $display("  [0x008] temp (sentinel -1, GAP-11) = %0d",
             $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[2]));
    for (int i = 0; i < 8; i++)
      $display("  [0x%0x] div[%0d]   = %0d", 'h020 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[8+i]));
    for (int i = 0; i < 8; i++)
      $display("  [0x%0x] dv_i[%0d]  = %0d", 'h040 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[16+i]));
    for (int i = 0; i < 8; i++)
      $display("  [0x%0x] dv_q[%0d]  = %0d", 'h060 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[24+i]));
    for (int i = 0; i < 8; i++)
      $display("  [0x%0x] cur_i[%0d] = %0d", 'h080 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[32+i]));
    for (int i = 0; i < 8; i++)
      $display("  [0x%0x] cur_q[%0d] = %0d", 'h0A0 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[40+i]));
    $finish;
  end
endmodule
