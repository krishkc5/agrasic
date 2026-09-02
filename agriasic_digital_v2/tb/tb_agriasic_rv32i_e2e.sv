// -----------------------------------------------------------------------------
// End-to-end testbench: RV32I firmware driving the real measurement FSM.
//
// Exercises the whole stack: program ROM -> core -> MMIO bridge -> measurement
// FSM -> excitation/SAR -> result back through MMIO to firmware.
//
// ADC model: returns a fixed code per excitation polarity, so the expected
// result is exact.
//   D+ = 200, D- = 100  ->  contribution = (200-100)/2 = 50 per pair
//   pair_log2 = 2       ->  4 pairs      -> accumulator = 200
//   firmware averages 4 identical measurements -> 200
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_agriasic_rv32i_e2e;

  localparam int unsigned ADC_WIDTH = 8;

  logic clk = 1'b0;
  logic rst_n;
  logic start_i;
  logic [ADC_WIDTH-1:0] adc_code_i;

  logic conv_start_o, exc_pol_o, busy_o, done_o;
  logic [15:0] result_o;
  logic [3:0]  cfg_pair_log2_o;
  logic [7:0]  cfg_settle_cycles_o, cfg_exc_divider_o, cfg_conv_cycles_o;

  always #5 clk = ~clk;

  // Deterministic ADC model keyed on excitation polarity.
  always_comb begin
    adc_code_i = exc_pol_o ? 8'd200 : 8'd100;
  end

  agriasic_digital_rv32i_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start_i             (start_i),
    .adc_code_i          (adc_code_i),
    .conv_start_o        (conv_start_o),
    .exc_pol_o           (exc_pol_o),
    .busy_o              (busy_o),
    .done_o              (done_o),
    .result_o            (result_o),
    .cfg_pair_log2_o     (cfg_pair_log2_o),
    .cfg_settle_cycles_o (cfg_settle_cycles_o),
    .cfg_exc_divider_o   (cfg_exc_divider_o),
    .cfg_conv_cycles_o   (cfg_conv_cycles_o)
  );

  // The shell's done_o (firmware reached ecall) is NOT exposed at the top --
  // those shell status outputs are currently dangling. Reach in for it here.
  wire fw_halted = dut.u_control_shell.done_o;

  // Scratch RAM: firmware writes its outputs here.
  //   0x100 -> OUT_AVERAGE  (word 64)
  //   0x104 -> OUT_COUNT    (word 65)
  //   0x110 -> OUT_SAMPLES  (word 68..71)
  localparam int W_AVERAGE = 'h100 / 4;
  localparam int W_COUNT   = 'h104 / 4;
  localparam int W_SAMPLES = 'h110 / 4;

  int unsigned cycles;
  int unsigned measurements_seen;
  int errors;

  // Count completed measurements by watching the FSM's done pulse.
  always_ff @(posedge clk) begin
    if (!rst_n) measurements_seen <= 0;
    else if (done_o) measurements_seen <= measurements_seen + 1;
  end

  // conv_start_o must be a single-cycle pulse -- the property the analog side
  // depends on.
  int unsigned conv_high_run;
  always_ff @(posedge clk) begin
    if (!rst_n) conv_high_run <= 0;
    else if (conv_start_o) begin
      conv_high_run <= conv_high_run + 1;
      if (conv_high_run >= 1) begin
        $error("conv_start_o held high for more than one cycle");
        errors <= errors + 1;
      end
    end else begin
      conv_high_run <= 0;
    end
  end

  // busy and done must never be simultaneously high.
  always_ff @(posedge clk) begin
    if (rst_n && busy_o && done_o) begin
      $error("busy_o and done_o both high at cycle %0d", cycles);
      errors <= errors + 1;
    end
  end

  initial begin
    errors  = 0;
    rst_n   = 1'b0;
    start_i = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("[TB] releasing start, firmware begins");
    start_i = 1'b1;

    // Wait for firmware to reach ecall.
    cycles = 0;
    while (!fw_halted && cycles < 100000) begin
      @(posedge clk);
      cycles++;
    end

    if (!fw_halted) begin
      $error("TIMEOUT: firmware did not halt within %0d cycles", cycles);
      errors++;
    end else begin
      $display("[TB] firmware halted after %0d cycles", cycles);
    end

    // Let the final stores retire.
    repeat (5) @(posedge clk);

    $display("[TB] measurements completed: %0d", measurements_seen);
    $display("[TB] config applied by firmware: pair_log2=%0d settle=%0d divider=%0d conv=%0d",
             cfg_pair_log2_o, cfg_settle_cycles_o, cfg_exc_divider_o, cfg_conv_cycles_o);

    check_word("OUT_COUNT",   W_COUNT,   32'd4);
    check_word("OUT_AVERAGE", W_AVERAGE, 32'd200);
    for (int i = 0; i < 4; i++) begin
      check_word($sformatf("OUT_SAMPLES[%0d]", i), W_SAMPLES + i, 32'd200);
    end

    if (cfg_pair_log2_o !== 4'd2) begin
      $error("cfg_pair_log2 = %0d, expected 2", cfg_pair_log2_o);
      errors++;
    end
    if (measurements_seen !== 4) begin
      $error("measurements_seen = %0d, expected 4", measurements_seen);
      errors++;
    end

    if (errors == 0) $display("[TB] PASS -- all checks passed");
    else             $display("[TB] FAIL -- %0d error(s)", errors);
    $finish;
  end

  task automatic check_word(string name, int idx, logic [31:0] expected);
    logic [31:0] actual;
    begin
      actual = dut.u_control_shell.u_mmio.u_dmem.ram_array[idx];
      if (actual !== expected) begin
        $error("%s (word %0d) = 0x%08x, expected 0x%08x", name, idx, actual, expected);
        errors++;
      end else begin
        $display("[TB] %s = %0d  OK", name, $signed(actual));
      end
    end
  endtask

endmodule
