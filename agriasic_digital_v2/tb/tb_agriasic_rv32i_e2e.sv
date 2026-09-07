// -----------------------------------------------------------------------------
// End-to-end testbench: RV32I firmware driving the real measurement FSM.
//
// Exercises the whole stack: program ROM -> core -> MMIO bridge -> measurement
// FSM -> excitation/SAR -> result back through MMIO to firmware.
//
// ADC model: returns a fixed code per I/Q sample phase (Rev 4.3 Phase 5), so
// the expected result on both channels is exact.
//   D(0)=200, D(180)=100 -> I contribution = 100/pair -> 4 pairs -> I = 400
//   D(90)=150, D(270)=80 -> Q contribution =  70/pair -> 4 pairs -> Q = 280
// This model is frequency-invariant (it keys on FSM state, not real analog
// response), so all three Rev 4.3 Phase 7 sweep points give the SAME I/Q
// numbers -- that is expected and correct here. What this test actually
// proves is the SWEEP MECHANISM: REG_DIVIDER really gets written to 1, then
// 100, then 10000 in sequence, each point's measurement completes and
// averages correctly, and results land in the right per-point scratch RAM
// slots. Real frequency-dependent soil response is outside what any
// testbench in this tree models (that would need an analog behavioral
// model, not a digital one).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_agriasic_rv32i_e2e;

  localparam int unsigned ADC_WIDTH = 8;

  logic clk = 1'b0;
  logic rst_n;
  logic start_i;

  logic conv_start_o, exc_drive_p_o, exc_drive_n_o, busy_o, done_o;
  logic adc_enable_o, adc_sample_o;
  logic [ADC_WIDTH-1:0] adc_dac_o;
  logic adc_comp_i;
  logic signed [15:0] result_i_o;
  logic signed [15:0] result_q_o;
  logic [3:0]  cfg_pair_log2_o;
  logic [7:0]  cfg_settle_cycles_o;
  logic [13:0] cfg_exc_divider_o;  // Rev 4.3 Phase 4.2 width; was left at [7:0] here, fixed
  logic [7:0]  cfg_conv_cycles_o;

  always #5 clk = ~clk;

  // Behavioral comparator model for the Rev 4.3 SAR bit-trial interface. See
  // sar_controller's header for the adc_comp_i convention this implements.
  // Rev 4.3 Phase 5: four distinct targets keyed on measurement_fsm's own
  // state -- see tb_agriasic_digital_top's header comment on this model for
  // why phase_index itself can't be used directly (one-cycle sample-accept
  // lag inside sar_controller at small divider values).
  //   3=S_SAMPLE_0 5=S_SAMPLE_180 8=S_SAMPLE_90 10=S_SAMPLE_270
  logic [ADC_WIDTH-1:0] adc_target_held_q;
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

  agriasic_digital_rv32i_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start_i             (start_i),
    .conv_start_o        (conv_start_o),
    .exc_drive_p_o       (exc_drive_p_o),
    .exc_drive_n_o       (exc_drive_n_o),
    .adc_enable_o        (adc_enable_o),
    .adc_sample_o        (adc_sample_o),
    .adc_dac_o           (adc_dac_o),
    .adc_comp_i          (adc_comp_i),
    .busy_o              (busy_o),
    .done_o              (done_o),
    .result_i_o          (result_i_o),
    .result_q_o          (result_q_o),
    .cfg_pair_log2_o     (cfg_pair_log2_o),
    .cfg_settle_cycles_o (cfg_settle_cycles_o),
    .cfg_exc_divider_o   (cfg_exc_divider_o),
    .cfg_conv_cycles_o   (cfg_conv_cycles_o)
  );

  // The shell's done_o (firmware reached ecall) is NOT exposed at the top --
  // those shell status outputs are currently dangling. Reach in for it here.
  wire fw_halted = dut.u_control_shell.done_o;

  // Scratch RAM: firmware writes its outputs here. Rev 4.3 Phase 7 layout
  // (supersedes the Phase 1-6 single-frequency-demo layout -- see fw.c):
  //   0x100 -> OUT_COUNT       (word 64)  measurements averaged per point
  //   0x104 -> OUT_NUM_POINTS  (word 65)  frequency points swept (3)
  //   0x110 -> OUT_DIV[0..2]   (words 68..70)  divider N used per point
  //   0x120 -> OUT_I[0..2]     (words 72..74)  I average per point
  //   0x130 -> OUT_Q[0..2]     (words 76..78)  Q average per point
  //   0x140 -> OUT_TEMP        (word 80)  sentinel -1, not implemented (GAP-11)
  localparam int W_COUNT      = 'h100 / 4;
  localparam int W_NUM_POINTS = 'h104 / 4;
  localparam int W_DIV        = 'h110 / 4;
  localparam int W_I          = 'h120 / 4;
  localparam int W_Q          = 'h130 / 4;
  localparam int W_TEMP       = 'h140 / 4;

  localparam int NUM_FREQ_POINTS  = 3;
  localparam int NUM_MEASUREMENTS = 2;

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

  // --------------------------------------------------------------------------
  // Rev 4.3 Phase 2.2: core clock enable must actually freeze the core.
  //
  // This reaches into the real trigger path (core_clk_en, driven by
  // start_pulse_o/measurement_done_i) rather than forcing a synthetic freeze,
  // so it verifies the mechanism this firmware run genuinely exercises four
  // times (once per measurement), not an artificial scenario.
  // --------------------------------------------------------------------------
  wire        core_clk_en_mon = dut.u_control_shell.core_clk_en;
  wire [31:0] pc_mon          = dut.u_control_shell.u_core.f_pc_current;

  int unsigned frozen_cycles;
  always_ff @(posedge clk) begin
    if (!rst_n) frozen_cycles <= 0;
    else if (!core_clk_en_mon) frozen_cycles <= frozen_cycles + 1;
  end

  property p_frozen_pc_holds;
    @(posedge clk) disable iff (!rst_n)
      !core_clk_en_mon |=> $stable(pc_mon);
  endproperty
  assert property (p_frozen_pc_holds)
    else $error("CLK_EN_FAIL: PC changed while core_clk_en was low");

  initial begin
    errors  = 0;
    rst_n   = 1'b0;
    start_i = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("[TB] releasing start, firmware begins");
    start_i = 1'b1;

    // Wait for firmware to reach ecall. Rev 4.3 Phase 7: the sweep includes
    // the real N=10000 (1 kHz) point, whose settle alone is 2 periods x 16 x
    // 10000 = 320,000 cycles, so the budget has to be generous -- see the
    // MAS Phase 7 note for the actual measured cycle count.
    cycles = 0;
    while (!fw_halted && cycles < 8000000) begin
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

    check_word("OUT_COUNT",      W_COUNT,      32'(NUM_MEASUREMENTS));
    check_word("OUT_NUM_POINTS", W_NUM_POINTS, 32'(NUM_FREQ_POINTS));
    check_word("OUT_TEMP",       W_TEMP,       32'hFFFFFFFF);  // sentinel -1

    check_word("OUT_DIV[0] (10 MHz)",  W_DIV + 0, 32'd1);
    check_word("OUT_DIV[1] (100 kHz)", W_DIV + 1, 32'd100);
    check_word("OUT_DIV[2] (1 kHz)",   W_DIV + 2, 32'd10000);

    // Frequency-invariant ADC model (see header): every point gives the
    // same I/Q numbers. That is the correct expectation here, not a bug --
    // see the header comment on what this test actually verifies.
    for (int p = 0; p < NUM_FREQ_POINTS; p++) begin
      check_word($sformatf("OUT_I[%0d]", p), W_I + p, 32'd400);
      check_word($sformatf("OUT_Q[%0d]", p), W_Q + p, 32'd280);
    end

    if (cfg_pair_log2_o !== 4'd2) begin
      $error("cfg_pair_log2 = %0d, expected 2", cfg_pair_log2_o);
      errors++;
    end
    if (measurements_seen !== NUM_FREQ_POINTS * NUM_MEASUREMENTS) begin
      $error("measurements_seen = %0d, expected %0d", measurements_seen,
             NUM_FREQ_POINTS * NUM_MEASUREMENTS);
      errors++;
    end

    $display("[TB] core_clk_en held low for %0d cycles across %0d measurements (%0s)",
             frozen_cycles, measurements_seen,
             (frozen_cycles > 0) ? "freeze mechanism exercised" : "WARNING: never froze");

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
