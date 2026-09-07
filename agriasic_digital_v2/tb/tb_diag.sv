`timescale 1ns / 1ns
module tb_diag;
  logic clk = 1'b0;
  logic rst_n, start_i;
  logic conv_start_o, exc_drive_p_o, exc_drive_n_o, busy_o, done_o;
  logic adc_enable_o, adc_sample_o;
  logic [7:0] adc_dac_o;
  logic adc_comp_i;
  logic signed [15:0] result_i_o;
  logic signed [15:0] result_q_o;
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

  agriasic_digital_rv32i_top dut (
    .clk(clk), .rst_n(rst_n), .start_i(start_i),
    .conv_start_o(conv_start_o), .exc_drive_p_o(exc_drive_p_o), .exc_drive_n_o(exc_drive_n_o),
    .adc_enable_o(adc_enable_o), .adc_sample_o(adc_sample_o),
    .adc_dac_o(adc_dac_o), .adc_comp_i(adc_comp_i),
    .busy_o(busy_o), .done_o(done_o), .result_i_o(result_i_o), .result_q_o(result_q_o),
    .cfg_pair_log2_o(cfg_pair_log2_o), .cfg_settle_cycles_o(cfg_settle_cycles_o),
    .cfg_exc_divider_o(cfg_exc_divider_o), .cfg_conv_cycles_o(cfg_conv_cycles_o));

  wire [31:0] pc = dut.u_control_shell.pc_to_imem;
  wire halted = dut.u_control_shell.done_o;
  wire mb = dut.u_control_shell.u_mmio.meas_busy_q;
  wire md = dut.u_control_shell.u_mmio.meas_done_q;

  int unsigned meas_count;
  always_ff @(posedge clk) if (!rst_n) meas_count <= 0; else if (done_o) meas_count <= meas_count + 1;

  int unsigned halt_seen;
  int unsigned maxpc;

  initial begin
    halt_seen = 0; maxpc = 0;
    rst_n = 0; start_i = 0;
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
    $display("scratch RAM (Rev 4.3 Phase 7 sweep layout -- see fw.c):");
    $display("  [0x100] count (per point)  = %0d", $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[64]));
    $display("  [0x104] num_points         = %0d", $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[65]));
    for (int i = 0; i < 3; i++)
      $display("  [0x%0x] div[%0d]  = %0d", 'h110 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[68+i]));
    for (int i = 0; i < 3; i++)
      $display("  [0x%0x] I[%0d]    = %0d", 'h120 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[72+i]));
    for (int i = 0; i < 3; i++)
      $display("  [0x%0x] Q[%0d]    = %0d", 'h130 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[76+i]));
    $display("  [0x140] temp (sentinel -1, GAP-11) = %0d",
             $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[80]));
    $finish;
  end
endmodule
