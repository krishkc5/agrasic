`timescale 1ns/1ps
// Diagnostic for the SPI path: does a CTRL.start write actually reach the
// measurement FSM?
module tb_spi_diag;
  localparam int unsigned ADC_WIDTH = 8;
  localparam logic [3:0] REG_CTRL      = 4'h0;
  localparam logic [3:0] REG_PAIR_LOG2 = 4'h1;
  localparam logic [3:0] REG_SETTLE    = 4'h2;
  localparam logic [3:0] REG_DIVIDER   = 4'h3;
  localparam logic [3:0] REG_CONV      = 4'h4;

  logic clk, rst_n, sclk_i, cs_n_i, mosi_i, miso_o;
  logic [ADC_WIDTH-1:0] adc_code_i;
  logic conv_start_o, exc_pol_o, busy_o, done_o;
  logic [15:0] result_o;

  agriasic_digital_spi_top #(.ADC_WIDTH(ADC_WIDTH)) dut (
    .clk(clk), .rst_n(rst_n), .sclk_i(sclk_i), .cs_n_i(cs_n_i),
    .mosi_i(mosi_i), .miso_o(miso_o), .adc_code_i(adc_code_i),
    .conv_start_o(conv_start_o), .exc_pol_o(exc_pol_o),
    .busy_o(busy_o), .done_o(done_o), .result_o(result_o));

  always #5 clk = ~clk;

  always_ff @(posedge clk) begin
    if (!rst_n) adc_code_i <= '0;
    else if (conv_start_o) adc_code_i <= exc_pol_o ? 8'd180 : 8'd60;
  end

  int unsigned start_pulses, rx_valids, done_pulses;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      start_pulses <= 0; rx_valids <= 0; done_pulses <= 0;
    end else begin
      if (dut.start_pulse_q) start_pulses <= start_pulses + 1;
      if (dut.spi_rx_valid)  rx_valids    <= rx_valids + 1;
      if (done_o)            done_pulses  <= done_pulses + 1;
    end
  end

  task automatic xfer(input logic [7:0] tx);
    int b;
    begin
      for (b = 7; b >= 0; b--) begin
        mosi_i = tx[b]; #20; sclk_i = 1'b1; #10; #10; sclk_i = 1'b0; #20;
      end
    end
  endtask

  logic [7:0] rd_byte;

  task automatic rd(input logic [3:0] addr);
    int b;
    begin
      cs_n_i = 1'b0;
      xfer({1'b1, addr, 3'b000});
      #120;
      // capture MISO while clocking the dummy byte
      for (b = 7; b >= 0; b--) begin
        mosi_i = 1'b0; #20; sclk_i = 1'b1; #10; rd_byte[b] = miso_o; #10; sclk_i = 1'b0; #20;
      end
      #60;
      cs_n_i = 1'b1;
      #200;
    end
  endtask

  task automatic wr(input logic [3:0] addr, input logic [7:0] data);
    begin
      cs_n_i = 1'b0;
      xfer({1'b0, addr, 3'b000});
      #120;
      xfer(data);
      #60;
      cs_n_i = 1'b1;
      #200;
    end
  endtask

  initial begin
    clk = 0; rst_n = 0; sclk_i = 0; cs_n_i = 1; mosi_i = 0;
    repeat (6) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    wr(REG_PAIR_LOG2, 8'h02);
    wr(REG_SETTLE,    8'h02);
    wr(REG_DIVIDER,   8'h00);
    wr(REG_CONV,      8'h01);

    $display("after config: rx_valids=%0d start_pulses=%0d", rx_valids, start_pulses);
    $display("  cfg regs in DUT: pair=%0d settle=%0d div=%0d conv=%0d",
             dut.cfg_pair_log2_q, dut.cfg_settle_q, dut.cfg_divider_q, dut.cfg_conv_q);

    // --- replicate the smoke test's error-injection sequence ---
    cs_n_i = 1'b0; xfer(8'h03); #120; xfer(8'h55); #60; cs_n_i = 1'b1; #200;
    $display("after invalid-cmd:  rx_valids=%0d rx_state=%0d flags[proto,addr,wr]=%b%b%b busy=%b",
             rx_valids, dut.rx_state_q, dut.status_protocol_err_q,
             dut.status_bad_addr_q, dut.status_illegal_wr_q, busy_o);
    rd(4'h5);
    $display("  after STATUS read:  rx_state=%0d miso_byte=0x%02h flags=%b%b%b",
             dut.rx_state_q, rd_byte, dut.status_protocol_err_q,
             dut.status_bad_addr_q, dut.status_illegal_wr_q);
    wr(4'hF, 8'hAA);
    $display("after bad-addr:     rx_valids=%0d rx_state=%0d", rx_valids, dut.rx_state_q);
    wr(4'h5, 8'h00);
    $display("after RO-write:     rx_valids=%0d rx_state=%0d", rx_valids, dut.rx_state_q);
    wr(REG_CTRL, 8'h80);
    $display("after clear-flags:  rx_valids=%0d rx_state=%0d pending_addr=%0d",
             rx_valids, dut.rx_state_q, dut.pending_addr_q);

    wr(REG_CTRL, 8'h01);
    $display("after CTRL start write: start_pulses=%0d rx_valids=%0d rx_state=%0d",
             start_pulses, rx_valids, dut.rx_state_q);
    $display("  fsm_state=%0d busy=%b done=%b",
             dut.u_core.u_measurement_fsm.state_q, busy_o, done_o);

    repeat (300) @(posedge clk);
    $display("=== after 300 more cycles ===");
    $display("  start_pulses=%0d done_pulses=%0d fsm_state=%0d busy=%b result=%0d",
             start_pulses, done_pulses,
             dut.u_core.u_measurement_fsm.state_q, busy_o, $signed(result_o));
    $finish;
  end
endmodule
