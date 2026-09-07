// -----------------------------------------------------------------------------
// Testbench: tb_settle_timing
// Purpose (history):
//   Originally a regression for two settle-path defects in the Rev 4.2
//   FSM-commanded excitation design: settle interval never applied (D-1),
//   and a deadlock whenever the settle countdown outlived the settle state
//   (D-2). Both were properties of the old set_phase_i/settled_o handshake,
//   which Rev 4.3 Phase 4 removed entirely -- excitation is free-running now,
//   there is no commanded flip left to mis-time or deadlock on. D-1/D-2
//   cannot regress because the mechanism that had them no longer exists.
//
// Purpose (current):
//   settle_cycles_i still exists, reinterpreted as excitation PERIODS to
//   wait after start (see measurement_fsm), and this test still earns its
//   keep verifying the NEW mechanism: no settle value hangs, and elapsed
//   time scales monotonically with settle_cycles_i.
//
// What this checks (no hardcoded cycle counts, so it survives retiming):
//   1. No configuration hangs.
//   2. Elapsed time strictly increases with settle_cycles_i -- settle has a
//      real, observable effect.
//   3. The accumulated result is correct and settle-independent.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module tb_settle_timing;

  localparam int unsigned BUDGET   = 4000;  // cycles before a run is called hung
  // Same four-target I/Q model as the smoke tests (section 6.11):
  // D(0)=220, D(180)=100, D(90)=170, D(270)=90.
  localparam int unsigned N_PAIRS  = 4;     // pair_log2 = 2
  // Raw accumulation, scaling is the host's job: M * (D+ - D-).
  localparam int signed EXPECTED_I = N_PAIRS * (220 - 100);
  localparam int signed EXPECTED_Q = N_PAIRS * (170 - 90);

  logic       clk = 1'b0;
  logic       rst_n = 1'b0;
  logic       start = 1'b0;
  logic [3:0] cfg_pair_log2_i;
  logic [7:0] cfg_settle_cycles_i;
  logic [13:0] cfg_exc_divider_i;
  logic [7:0] cfg_conv_cycles_i;
  logic       conv_start_o;
  logic       exc_drive_p_o;
  logic       exc_drive_n_o;
  logic       adc_enable_o;
  logic       adc_sample_o;
  logic [7:0] adc_dac_o;
  logic       adc_comp_i;
  logic       busy_o;
  logic       done_o;
  logic signed [15:0] result_i_o;
  logic signed [15:0] result_q_o;

  int errors = 0;

  always #5 clk = ~clk;

  agriasic_digital_top dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start               (start),
    .cfg_pair_log2_i     (cfg_pair_log2_i),
    .cfg_settle_cycles_i (cfg_settle_cycles_i),
    .cfg_exc_divider_i   (cfg_exc_divider_i),
    .cfg_conv_cycles_i   (cfg_conv_cycles_i),
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
    .result_q_o          (result_q_o)
  );

  // Behavioral comparator model for the Rev 4.3 SAR bit-trial interface. See
  // sar_controller's header for the adc_comp_i convention this implements.
  // Rev 4.3 Phase 5: four distinct targets keyed on measurement_fsm's own
  // state -- see tb_agriasic_digital_top's header comment on this model for
  // why phase_index itself can't be used directly (one-cycle sample-accept
  // lag inside sar_controller).
  //   3=S_SAMPLE_0 5=S_SAMPLE_180 8=S_SAMPLE_90 10=S_SAMPLE_270
  logic [7:0] adc_target_held_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (4'(dut.u_measurement_fsm.state_q))
        4'd3:  adc_target_held_q <= 8'd220;
        4'd8:  adc_target_held_q <= 8'd170;
        4'd5:  adc_target_held_q <= 8'd100;
        4'd10: adc_target_held_q <= 8'd90;
        default: begin end
      endcase
    end
  end
  assign adc_comp_i = (adc_target_held_q >= adc_dac_o);

  int  elapsed;
  bit  hung;
  int  captured_i;
  int  captured_q;

  // Run one measurement at the given settle/conv configuration.
  task automatic run_one(input logic [7:0] settle, input logic [7:0] conv);
    int n;
    begin
      @(negedge clk);
      rst_n               = 1'b0;
      start               = 1'b0;
      cfg_pair_log2_i     = 4'd2;
      cfg_exc_divider_i   = 14'd1;
      cfg_settle_cycles_i = settle;
      cfg_conv_cycles_i   = conv;
      repeat (4) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;

      n = 0;
      while (done_o !== 1'b1 && n < BUDGET) begin
        @(posedge clk);
        n = n + 1;
      end
      hung       = (done_o !== 1'b1);
      elapsed    = n;
      captured_i = int'(result_i_o);
      captured_q = int'(result_q_o);
    end
  endtask

  // Run and check: must not hang, and must produce the expected accumulation
  // on both channels.
  task automatic check_run(input logic [7:0] settle, input logic [7:0] conv,
                           output int el);
    begin
      run_one(settle, conv);
      if (hung) begin
        $error("SETTLE_HANG: settle=%0d conv=%0d did not complete in %0d cycles",
               settle, conv, BUDGET);
        errors++;
        el = -1;
      end else begin
        if (captured_i !== EXPECTED_I) begin
          $error("SETTLE_RESULT_FAIL: settle=%0d conv=%0d expected I=%0d got=%0d",
                 settle, conv, EXPECTED_I, captured_i);
          errors++;
        end
        if (captured_q !== EXPECTED_Q) begin
          $error("SETTLE_RESULT_FAIL: settle=%0d conv=%0d expected Q=%0d got=%0d",
                 settle, conv, EXPECTED_Q, captured_q);
          errors++;
        end
        el = elapsed;
        $display("[TB]   settle=%0d conv=%0d -> %0d cycles, I=%0d Q=%0d",
                 settle, conv, elapsed, captured_i, captured_q);
      end
    end
  endtask

  int e0, e2, e5, e20;

  initial begin
    $display("[TB] settle timing regression (expected I=%0d Q=%0d)", EXPECTED_I, EXPECTED_Q);

    // Defect 2: every one of these hung before the fix.
    check_run(8'd0,  8'd1, e0);
    check_run(8'd2,  8'd1, e2);
    check_run(8'd5,  8'd1, e5);
    check_run(8'd20, 8'd1, e20);

    // Defect 1: settle must have a real, monotonic effect on run length.
    if (e0 >= 0 && e2 >= 0 && e5 >= 0 && e20 >= 0) begin
      if (!(e0 < e2 && e2 < e5 && e5 < e20)) begin
        $error("SETTLE_NO_EFFECT: elapsed cycles not strictly increasing with settle (%0d, %0d, %0d, %0d)",
               e0, e2, e5, e20);
        errors++;
      end else begin
        $display("[TB]   elapsed strictly increases with settle: %0d < %0d < %0d < %0d",
                 e0, e2, e5, e20);
      end
    end

    if (errors == 0) begin
      $display("SETTLE_TIMING_PASS");
    end else begin
      $display("SETTLE_TIMING_FAIL: %0d error(s)", errors);
    end
    $finish;
  end

endmodule
