`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_accum_edge_cases
// Purpose (Rev 4.3 Phase 8, closes verification item V-2):
//   V-2 in the original verification plan (MAS section 12.3) was written
//   against the Rev 4.2 design, where D-3 was a per-pair right-shift that
//   rounded toward negative infinity -- a bug that specifically hides in
//   odd, +/-1, and saturating differences. That shift no longer exists
//   anywhere in the arithmetic path (measurement_fsm does a single signed
//   subtraction and a single signed addition per sample, section 6.1), so
//   the exact defect class V-2 was written to catch is now structurally
//   impossible, not just fixed -- there is nothing left to round.
//
//   This test still earns its keep as a regression: it proves the current
//   arithmetic is EXACT (no hidden truncation, no off-by-one in the
//   accumulate path) at the three input classes V-2 names, and would catch
//   a REGRESSION if scaling were ever reintroduced. pair_log2=0 (M=1) is
//   used for the odd and +/-1 cases so each run checks a single pair's raw
//   delta directly, with no averaging to obscure a bug. The saturating case
//   uses the real M=64 clamp (section 9.3) to check the actual worst-case
//   magnitude the design is specified against: 64 x 255 = 16320.
//
// Cases:
//   A: M=1,  D(0)=155 D(180)=100 -> delta=55   (odd)
//   B: M=1,  D(0)=101 D(180)=100 -> delta=+1   (+1)
//   C: M=1,  D(0)=100 D(180)=101 -> delta=-1   (-1, exercises negative accumulation)
//   D: M=64, D(0)=255 D(180)=0   -> delta=16320 (saturating, the real section 9.3 worst case)
// Q channel is checked alongside I in every case using the same D(90)/D(270)
// pattern, not because V-2 calls for it, but because it is free once I is
// already being verified per run.
// -----------------------------------------------------------------------------
module tb_accum_edge_cases;
  localparam int unsigned ADC_WIDTH = 8;

  logic clk;
  logic rst_n;
  logic start;
  logic [3:0]  cfg_pair_log2_i;
  logic [7:0]  cfg_settle_cycles_i;
  logic [13:0] cfg_exc_divider_i;
  logic [7:0]  cfg_conv_cycles_i;
  logic conv_start_o;
  logic exc_drive_p_o;
  logic exc_drive_n_o;
  logic adc_enable_o;
  logic adc_sample_o;
  logic [ADC_WIDTH-1:0] adc_dac_o;
  logic adc_comp_i;
  logic busy_o;
  logic done_o;
  logic signed [15:0] result_i_o;
  logic signed [15:0] result_q_o;

  // Behavioral-model targets, settable per run before each start pulse.
  logic [ADC_WIDTH-1:0] d0_target_q, d90_target_q, d180_target_q, d270_target_q;

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .cfg_pair_log2_i(cfg_pair_log2_i),
    .cfg_settle_cycles_i(cfg_settle_cycles_i),
    .cfg_exc_divider_i(cfg_exc_divider_i),
    .cfg_conv_cycles_i(cfg_conv_cycles_i),
    .conv_start_o(conv_start_o),
    .exc_drive_p_o(exc_drive_p_o),
    .exc_drive_n_o(exc_drive_n_o),
    .adc_enable_o(adc_enable_o),
    .adc_sample_o(adc_sample_o),
    .adc_dac_o(adc_dac_o),
    .adc_comp_i(adc_comp_i),
    .busy_o(busy_o),
    .done_o(done_o),
    .result_i_o(result_i_o),
    .result_q_o(result_q_o)
  );

  always #5 clk = ~clk;

  // Same state-keyed track-and-hold model as the other testbenches (see
  // tb_agriasic_digital_top.sv's header for why state, not phase_index, is
  // the correct thing to key on), but with runtime-settable targets so each
  // case can reconfigure the model between runs.
  //   3=S_SAMPLE_0 5=S_SAMPLE_180 8=S_SAMPLE_90 10=S_SAMPLE_270
  logic [ADC_WIDTH-1:0] adc_target_held_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (4'(dut.u_measurement_fsm.state_q))
        4'd3:  adc_target_held_q <= d0_target_q;
        4'd8:  adc_target_held_q <= d90_target_q;
        4'd5:  adc_target_held_q <= d180_target_q;
        4'd10: adc_target_held_q <= d270_target_q;
        default: begin end
      endcase
    end
  end
  assign adc_comp_i = (adc_target_held_q >= adc_dac_o);

  int errors;

  task automatic run_case(
    input string label,
    input logic [3:0] pair_log2,
    input logic [ADC_WIDTH-1:0] d0, d90, d180, d270,
    input logic signed [15:0] expected_i,
    input logic signed [15:0] expected_q,
    input int budget
  );
    int n;
    begin
      @(negedge clk);
      d0_target_q   = d0;
      d90_target_q  = d90;
      d180_target_q = d180;
      d270_target_q = d270;
      cfg_pair_log2_i     = pair_log2;
      cfg_settle_cycles_i = 8'd2;
      cfg_exc_divider_i   = 14'd1;
      cfg_conv_cycles_i   = 8'd1;

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;

      n = 0;
      while (!done_o && n < budget) begin
        @(posedge clk);
        n++;
      end

      if (!done_o) begin
        $error("ACCUM_EDGE_HANG: case %s did not complete in %0d cycles", label, budget);
        errors++;
      end else begin
        if (result_i_o !== expected_i) begin
          $error("ACCUM_EDGE_FAIL: case %s expected I=%0d got=%0d", label, expected_i, result_i_o);
          errors++;
        end
        if (result_q_o !== expected_q) begin
          $error("ACCUM_EDGE_FAIL: case %s expected Q=%0d got=%0d", label, expected_q, result_q_o);
          errors++;
        end
        if (result_i_o === expected_i && result_q_o === expected_q) begin
          $display("[TB] case %-24s I=%0d Q=%0d (%0d cycles) OK", label, result_i_o, result_q_o, n);
        end
      end

      // Let done_o's one-cycle window pass before the next start pulse.
      @(negedge clk);
    end
  endtask

  initial begin
    errors = 0;
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    d0_target_q = '0; d90_target_q = '0; d180_target_q = '0; d270_target_q = '0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[TB] accumulator edge cases (Rev 4.3 Phase 8, V-2)");

    // Case A: odd difference, M=1.
    run_case("A_odd",   4'd0, 8'd155, 8'd200, 8'd100, 8'd150, 16'sd55,  16'sd50,  2000);
    // Case B: +1 difference, M=1.
    run_case("B_plus1", 4'd0, 8'd101, 8'd200, 8'd100, 8'd150, 16'sd1,   16'sd50,  2000);
    // Case C: -1 difference, M=1.
    run_case("C_minus1",4'd0, 8'd100, 8'd200, 8'd101, 8'd150, -16'sd1,  16'sd50,  2000);
    // Case D: saturating, M=64 (the real section 9.3 worst case).
    run_case("D_saturating", 4'd6, 8'd255, 8'd255, 8'd0, 8'd0, 16'sd16320, 16'sd16320, 200000);

    if (errors == 0) $display("ACCUM_EDGE_PASS");
    else             $display("ACCUM_EDGE_FAIL: %0d error(s)", errors);
    $finish;
  end
endmodule
