`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_agriasic_digital_top
// Purpose:
//   Minimal smoke test for top-level digital integration.
//
// What this test currently checks:
//   1) Reset deassertion and basic clocking.
//   2) A single start pulse into the measurement flow.
//   3) Activity propagation through placeholder control/data path.
//   4) End-of-test visibility of done/result signals.
//
// Notes:
//   - This is not a self-checking compliance test yet.
//   - Future versions should add assertions, scoreboard checks, and protocol
//     stimulus for SPI/register programming.
// -----------------------------------------------------------------------------
module tb_agriasic_digital_top;
  localparam int unsigned ADC_WIDTH = 8;
  localparam int unsigned EXPECTED_RESULT = 16'd240;

  logic clk;
  logic rst_n;
  logic start;
  logic [3:0] cfg_pair_log2_i;
  logic [7:0] cfg_settle_cycles_i;
  logic [7:0] cfg_exc_divider_i;
  logic [7:0] cfg_conv_cycles_i;
  logic [ADC_WIDTH-1:0] adc_code_i;
  logic conv_start_o;
  logic exc_pol_o;
  logic busy_o;
  logic done_o;
  logic [15:0] result_o;

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
    .adc_code_i(adc_code_i),
    .conv_start_o(conv_start_o),
    .exc_pol_o(exc_pol_o),
    .busy_o(busy_o),
    .done_o(done_o),
    .result_o(result_o)
  );

  // 100 MHz equivalent simulation clock.
  always #5 clk = ~clk;

  initial begin
    // Initialize DUT inputs.
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    cfg_pair_log2_i = 4'd2;      // 2^2 = 4 pairs
    cfg_settle_cycles_i = 8'd2;  // settle ticks per phase
    cfg_exc_divider_i = 8'd0;    // tick every core cycle
    cfg_conv_cycles_i = 8'd1;    // short conversion latency
    adc_code_i = '0;

    // Hold reset for a few cycles.
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    // Fire one measurement command pulse.
    @(posedge clk);
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    // Drive ADC code based on phase when conversion is requested.
    // Positive phase code is higher than negative phase code, yielding
    // pair_delta = (180 - 60) / 2 = 60. With 4 pairs, expected result is 240.
    repeat (200) begin
      @(posedge clk);
      if (conv_start_o) begin
        adc_code_i <= exc_pol_o ? 8'd180 : 8'd60;
      end

      if (done_o) begin
        if (result_o !== EXPECTED_RESULT) begin
          $error("SMOKE_FAIL: expected=%0d got=%0d", EXPECTED_RESULT, result_o);
        end else begin
          $display("SMOKE_PASS: result=%0d", result_o);
        end
        $finish;
      end
    end

    $error("SMOKE_TIMEOUT: done was not asserted in expected window");
    $finish;
  end
endmodule
