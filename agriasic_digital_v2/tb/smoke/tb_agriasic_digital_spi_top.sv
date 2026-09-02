`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_agriasic_digital_spi_top
// Purpose:
//   Smoke test for SPI-controlled wrapper.
//
// Coverage in this test:
//   - Writes config registers through SPI.
//   - Issues start command through SPI.
//   - Drives ADC codes according to excitation polarity during conversions.
//   - Reads status/result back through SPI and checks expected value.
// -----------------------------------------------------------------------------
module tb_agriasic_digital_spi_top;
  localparam int unsigned ADC_WIDTH = 8;
  localparam int unsigned EXPECTED_RESULT = 16'd240;

  localparam logic [3:0] REG_CTRL      = 4'h0;
  localparam logic [3:0] REG_PAIR_LOG2 = 4'h1;
  localparam logic [3:0] REG_SETTLE    = 4'h2;
  localparam logic [3:0] REG_DIVIDER   = 4'h3;
  localparam logic [3:0] REG_CONV      = 4'h4;
  localparam logic [3:0] REG_STATUS    = 4'h5;
  localparam logic [3:0] REG_RESULT_LO = 4'h6;
  localparam logic [3:0] REG_RESULT_HI = 4'h7;
  localparam logic [3:0] REG_INVALID    = 4'hF;

  logic clk;
  logic rst_n;
  logic sclk_i;
  logic cs_n_i;
  logic mosi_i;
  logic miso_o;
  logic [ADC_WIDTH-1:0] adc_code_i;
  logic conv_start_o;
  logic exc_pol_o;
  logic busy_o;
  logic done_o;
  logic [15:0] result_o;

  logic [7:0] status_byte;
  logic [7:0] result_lo;
  logic [7:0] result_hi;
  logic [7:0] cmd_phase_rx;
  int unsigned wait_cycles;

  agriasic_digital_spi_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .sclk_i(sclk_i),
    .cs_n_i(cs_n_i),
    .mosi_i(mosi_i),
    .miso_o(miso_o),
    .adc_code_i(adc_code_i),
    .conv_start_o(conv_start_o),
    .exc_pol_o(exc_pol_o),
    .busy_o(busy_o),
    .done_o(done_o),
    .result_o(result_o)
  );

  always #5 clk = ~clk;

  // When conversion starts, drive a deterministic ADC code pair.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      adc_code_i <= '0;
    end else if (conv_start_o) begin
      adc_code_i <= exc_pol_o ? 8'd180 : 8'd60;
    end
  end

  task automatic spi_transfer_byte(
    input  logic [7:0] tx,
    output logic [7:0] rx
  );
    int b;
    begin
      rx = 8'h00;
      for (b = 7; b >= 0; b--) begin
        mosi_i = tx[b];
        #20;
        sclk_i = 1'b1;
        #10;
        rx[b] = miso_o;
        #10;
        sclk_i = 1'b0;
        #20;
      end
    end
  endtask

  task automatic spi_write_reg(input logic [3:0] addr, input logic [7:0] data);
    logic [7:0] throw_away;
    logic [7:0] cmd;
    begin
      cmd = {1'b0, addr, 3'b000};
      cs_n_i = 1'b0;
      spi_transfer_byte(cmd, throw_away);
      #120;
      spi_transfer_byte(data, throw_away);
      #60;
      cs_n_i = 1'b1;
      #200;
    end
  endtask

  task automatic spi_write_cmd_raw(input logic [7:0] cmd, input logic [7:0] data);
    logic [7:0] throw_away;
    begin
      cs_n_i = 1'b0;
      spi_transfer_byte(cmd, throw_away);
      #120;
      spi_transfer_byte(data, throw_away);
      #60;
      cs_n_i = 1'b1;
      #200;
    end
  endtask

  // Returns first-byte MISO stream while issuing a command byte.
  task automatic spi_capture_cmd_phase(input logic [7:0] cmd, output logic [7:0] rx_cmd_phase);
    logic [7:0] throw_away;
    begin
      cs_n_i = 1'b0;
      spi_transfer_byte(cmd, rx_cmd_phase);
      #120;
      spi_transfer_byte(8'h00, throw_away);
      #60;
      cs_n_i = 1'b1;
      #200;
    end
  endtask

  task automatic spi_read_reg(input logic [3:0] addr, output logic [7:0] data);
    logic [7:0] throw_away;
    logic [7:0] cmd;
    begin
      cmd = {1'b1, addr, 3'b000};
      cs_n_i = 1'b0;
      spi_transfer_byte(cmd, throw_away);
      #120;
      spi_transfer_byte(8'h00, data);
      #60;
      cs_n_i = 1'b1;
      #200;
    end
  endtask

  // Basic protocol assertions.
  property p_conv_start_single_cycle;
    @(posedge clk) disable iff (!rst_n)
      conv_start_o |=> !conv_start_o;
  endproperty

  property p_done_not_busy;
    @(posedge clk) disable iff (!rst_n)
      done_o |-> !busy_o;
  endproperty

  assert property (p_conv_start_single_cycle)
    else $error("ASSERT_FAIL: conv_start_o must be single-cycle pulse");

  assert property (p_done_not_busy)
    else $error("ASSERT_FAIL: done_o and busy_o cannot be high together");

  initial begin
    clk      = 1'b0;
    rst_n    = 1'b0;
    sclk_i   = 1'b0;
    cs_n_i   = 1'b1;
    mosi_i   = 1'b0;
    adc_code_i = '0;

    repeat (6) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Program core behavior: 4 pairs, settle=2, divider=0, conv=1
    spi_write_reg(REG_PAIR_LOG2, 8'h02);
    spi_write_reg(REG_SETTLE,    8'h02);
    spi_write_reg(REG_DIVIDER,   8'h00);
    spi_write_reg(REG_CONV,      8'h01);

    // Inject invalid command (reserved bits set) and check status flag [7].
    spi_write_cmd_raw(8'h03, 8'h55);
    spi_read_reg(REG_STATUS, status_byte);
    if (status_byte[7] !== 1'b1) begin
      $error("SPI_TOP_PROTO_FLAG_FAIL: expected protocol error flag set, got 0x%0h", status_byte);
      $finish;
    end

    // Inject invalid register address and check status flag [6].
    spi_write_reg(REG_INVALID, 8'hAA);
    spi_read_reg(REG_STATUS, status_byte);
    if (status_byte[6] !== 1'b1) begin
      $error("SPI_TOP_BAD_ADDR_FLAG_FAIL: expected bad addr flag set, got 0x%0h", status_byte);
      $finish;
    end

    // Attempt write to read-only status register and check flag [5].
    spi_write_reg(REG_STATUS, 8'h00);
    spi_read_reg(REG_STATUS, status_byte);
    if (status_byte[5] !== 1'b1) begin
      $error("SPI_TOP_ILLEGAL_WR_FLAG_FAIL: expected illegal write flag set, got 0x%0h", status_byte);
      $finish;
    end

    // Clear sticky protocol flags with CTRL bit7.
    spi_write_reg(REG_CTRL, 8'h80);
    spi_read_reg(REG_STATUS, status_byte);
    if (status_byte[7:5] !== 3'b000) begin
      $error("SPI_TOP_CLEAR_FLAGS_FAIL: expected flags cleared, got 0x%0h", status_byte);
      $finish;
    end

    // Trigger one measurement run via CTRL.start bit.
    spi_write_reg(REG_CTRL,      8'h01);

    wait_cycles = 0;
    while (!done_o && wait_cycles < 1000) begin
      @(posedge clk);
      wait_cycles++;
    end

    if (!done_o) begin
      $error("SPI_TOP_TIMEOUT: done_o did not assert");
      $finish;
    end

    // Read back status and result via SPI.
    spi_read_reg(REG_STATUS, status_byte);
    spi_read_reg(REG_RESULT_LO, result_lo);
    spi_read_reg(REG_RESULT_HI, result_hi);

    // Capture command-phase response byte to ensure wrapper is driving response
    // stream continuously. Read command for STATUS should return some previous
    // response byte on cmd phase; this checks path activity, not exact value.
    spi_capture_cmd_phase({1'b1, REG_STATUS, 3'b000}, cmd_phase_rx);
    if (^cmd_phase_rx === 1'bx) begin
      $error("SPI_TOP_CMD_PHASE_FAIL: command-phase response contains Xs");
      $finish;
    end

    if (status_byte[1] !== 1'b1) begin
      $error("SPI_TOP_STATUS_FAIL: expected done bit set, got status=0x%0h", status_byte);
      $finish;
    end

    if ({result_hi, result_lo} !== EXPECTED_RESULT[15:0]) begin
      $error(
        "SPI_TOP_RESULT_FAIL: expected=%0d got=%0d (hi=0x%0h lo=0x%0h)",
        EXPECTED_RESULT,
        {result_hi, result_lo},
        result_hi,
        result_lo
      );
      $finish;
    end

    $display("SPI_TOP_SMOKE_PASS: status=0x%0h result=%0d", status_byte, {result_hi, result_lo});
    $finish;
  end
endmodule
