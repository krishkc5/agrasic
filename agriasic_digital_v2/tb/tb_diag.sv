`timescale 1ns / 1ns
module tb_diag;
  logic clk = 1'b0;
  logic rst_n, start_i;
  logic [7:0] adc_code_i;
  logic conv_start_o, exc_pol_o, busy_o, done_o;
  logic [15:0] result_o;
  logic [3:0] cfg_pair_log2_o;
  logic [7:0] cfg_settle_cycles_o, cfg_exc_divider_o, cfg_conv_cycles_o;

  always #5 clk = ~clk;
  always_comb adc_code_i = exc_pol_o ? 8'd200 : 8'd100;

  agriasic_digital_rv32i_top dut (
    .clk(clk), .rst_n(rst_n), .start_i(start_i), .adc_code_i(adc_code_i),
    .conv_start_o(conv_start_o), .exc_pol_o(exc_pol_o), .busy_o(busy_o),
    .done_o(done_o), .result_o(result_o),
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

    for (int c = 0; c < 4000; c++) begin
      @(posedge clk);
      if (halted) halt_seen++;
      if (pc > maxpc) maxpc = pc;
      if (c % 200 == 0)
        $display("c%0d pc=%02x meas=%0d mmio_busy=%b mmio_done=%b halted=%b",
                 c, pc, meas_count, mb, md, halted);
    end

    $display("=== summary ===");
    $display("measurements completed : %0d", meas_count);
    $display("max PC reached         : 0x%02x", maxpc);
    $display("halt asserted (cycles) : %0d", halt_seen);
    $display("scratch RAM:");
    $display("  [0x100] average = %0d", $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[64]));
    $display("  [0x104] count   = %0d", $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[65]));
    for (int i = 0; i < 4; i++)
      $display("  [0x%0x] sample%0d = %0d", 'h110 + 4*i, i,
               $signed(dut.u_control_shell.u_mmio.u_dmem.ram_array[68+i]));
    $finish;
  end
endmodule
