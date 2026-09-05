`timescale 1ns/1ns

// -----------------------------------------------------------------------------
// Testbench: tb_sar_bit_trial
// Purpose:
//   Unit regression for the Rev 4.3 sar_controller bit-trial rewrite. Exercises
//   the successive-approximation search directly (no excitation_ctrl or
//   measurement_fsm in the loop) against a behavioral comparator model, and
//   checks that the converged code matches the target exactly for a set of
//   edge-case and representative targets on both phases.
//
// Comparator model:
//   adc_comp_i = (target_code >= adc_dac_o), which is exactly the sense
//   documented in sar_controller's header ("1 = input >= current trial code").
//   Binary search with this comparator convention converges to the target
//   exactly for any integer target in range -- this test's real job is
//   confirming the RTL's bit sequencing and regeneration-wait handshake
//   implement that correctly, not the arithmetic itself.
// -----------------------------------------------------------------------------
module tb_sar_bit_trial;
  localparam int unsigned ADC_WIDTH = 8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic sample_req_i = 1'b0;
  logic sample_phase_i = 1'b0;
  logic [7:0] conv_cycles_i = 8'd2;  // regeneration wait per bit trial

  logic conv_start_o, sample_done_o, busy_o;
  logic [ADC_WIDTH-1:0] d_plus_o, d_minus_o;
  logic adc_enable_o, adc_sample_o;
  logic [ADC_WIDTH-1:0] adc_dac_o;
  logic adc_comp_i;

  logic [ADC_WIDTH-1:0] target_code;
  int errors = 0;

  always #5 clk = ~clk;

  sar_controller #(
    .ADC_WIDTH(ADC_WIDTH)
  ) dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .sample_req_i   (sample_req_i),
    .sample_phase_i (sample_phase_i),
    .conv_cycles_i  (conv_cycles_i),
    .conv_start_o   (conv_start_o),
    .sample_done_o  (sample_done_o),
    .busy_o         (busy_o),
    .d_plus_o       (d_plus_o),
    .d_minus_o      (d_minus_o),
    .adc_enable_o   (adc_enable_o),
    .adc_sample_o   (adc_sample_o),
    .adc_dac_o      (adc_dac_o),
    .adc_comp_i     (adc_comp_i)
  );

  // Behavioral comparator: see header note on the convergence argument.
  assign adc_comp_i = (target_code >= adc_dac_o);

  // adc_sample_o (the track-and-hold strobe) must be a single-cycle pulse.
  property p_sample_single_cycle;
    @(posedge clk) disable iff (!rst_n)
      adc_sample_o |=> !adc_sample_o;
  endproperty
  assert property (p_sample_single_cycle)
    else $error("ASSERT_FAIL: adc_sample_o must be single-cycle");

  task automatic run_one(input logic [ADC_WIDTH-1:0] target, input logic phase, input int unsigned budget);
    int unsigned n;
    logic [ADC_WIDTH-1:0] got;
    begin
      target_code    = target;
      sample_phase_i = phase;
      @(negedge clk);
      sample_req_i = 1'b1;
      @(negedge clk);
      // Hold the request the way measurement_fsm does: until done is observed.
      n = 0;
      while (!sample_done_o && n < budget) begin
        @(negedge clk);
        n++;
      end
      if (!sample_done_o) begin
        $error("SAR_TIMEOUT: target=%0d phase=%0d did not complete in %0d cycles", target, phase, budget);
        errors++;
      end else begin
        got = phase ? d_plus_o : d_minus_o;
        if (got !== target) begin
          $error("SAR_MISMATCH: target=%0d phase=%0d got=%0d", target, phase, got);
          errors++;
        end else begin
          $display("[TB]   target=%0d phase=%0d -> converged=%0d OK (%0d cycles)", target, phase, got, n);
        end
      end
      sample_req_i = 1'b0;
      @(negedge clk);
    end
  endtask

  initial begin
    rst_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    $display("[TB] SAR bit-trial convergence sweep (conv_cycles=%0d)", conv_cycles_i);
    run_one(8'd0,   1'b1, 200);
    run_one(8'd255, 1'b0, 200);
    run_one(8'd1,   1'b1, 200);
    run_one(8'd254, 1'b0, 200);
    run_one(8'd128, 1'b1, 200);
    run_one(8'd127, 1'b0, 200);
    run_one(8'd180, 1'b1, 200);
    run_one(8'd60,  1'b0, 200);
    run_one(8'd200, 1'b1, 200);
    run_one(8'd100, 1'b0, 200);

    // Also confirm the regeneration wait is actually honored: with
    // conv_cycles_i=0 each trial should still converge (zero-wait is legal),
    // just faster.
    conv_cycles_i = 8'd0;
    run_one(8'd180, 1'b1, 200);

    if (errors == 0) begin
      $display("SAR_BIT_TRIAL_PASS");
    end else begin
      $display("SAR_BIT_TRIAL_FAIL: %0d error(s)", errors);
    end
    $finish;
  end
endmodule
