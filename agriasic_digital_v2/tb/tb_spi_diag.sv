`timescale 1ns/1ps
// Diagnostic for the SPI path: does a CTRL.start write actually reach the
// measurement FSM?
module tb_spi_diag;
  localparam int unsigned ADC_WIDTH = 8;
  // Rev 4.3 Phase 6 register map -- see agriasic_digital_spi_top.sv's header.
  localparam logic [3:0] REG_CTRL      = 4'h0;
  localparam logic [3:0] REG_PAIR_LOG2 = 4'h1;
  localparam logic [3:0] REG_SETTLE    = 4'h2;
  localparam logic [3:0] REG_FREQ_SEL  = 4'h3;
  localparam logic [3:0] REG_CONV      = 4'h5;
  localparam logic [3:0] REG_STATUS    = 4'h6;

  logic clk, rst_n, sclk_i, cs_n_i, mosi_i, miso_o, miso_oe_o;
  logic conv_start_o, exc_drive_p_o, exc_drive_n_o, busy_o, done_o;
  logic adc_enable_o, adc_sample_o;
  logic [ADC_WIDTH-1:0] adc_dac_o;
  logic adc_comp_i;
  logic signed [15:0] result_i_o;
  logic signed [15:0] result_q_o;

  agriasic_digital_spi_top #(.ADC_WIDTH(ADC_WIDTH)) dut (
    .clk(clk), .rst_n(rst_n), .sclk_i(sclk_i), .cs_n_i(cs_n_i),
    .mosi_i(mosi_i), .miso_o(miso_o), .miso_oe_o(miso_oe_o),
    .conv_start_o(conv_start_o), .exc_drive_p_o(exc_drive_p_o), .exc_drive_n_o(exc_drive_n_o),
    .adc_enable_o(adc_enable_o), .adc_sample_o(adc_sample_o),
    .adc_dac_o(adc_dac_o), .adc_comp_i(adc_comp_i),
    .busy_o(busy_o), .done_o(done_o), .result_i_o(result_i_o), .result_q_o(result_q_o));

  always #5 clk = ~clk;

  // Behavioral comparator model -- see sar_controller's header for the
  // adc_comp_i convention this implements.
  // Rev 4.3 Phase 5: four distinct targets keyed on measurement_fsm's own
  // state -- see tb_agriasic_digital_top's header comment on this model.
  //   3=S_SAMPLE_0 5=S_SAMPLE_180 8=S_SAMPLE_90 10=S_SAMPLE_270
  logic [ADC_WIDTH-1:0] adc_target_held_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (4'(dut.u_core.u_measurement_fsm.state_q))
        4'd3:  adc_target_held_q <= 8'd180;  // D(0)
        4'd8:  adc_target_held_q <= 8'd130;  // D(90)
        4'd5:  adc_target_held_q <= 8'd60;   // D(180)
        4'd10: adc_target_held_q <= 8'd50;   // D(270)
        default: begin end
      endcase
    end
  end
  assign adc_comp_i = (adc_target_held_q >= adc_dac_o);

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
        mosi_i = tx[b]; #80; sclk_i = 1'b1; #40; #40; sclk_i = 1'b0; #80;
      end
    end
  endtask

  logic [7:0] rd_byte;

  task automatic rd(input logic [3:0] addr);
    int b;
    begin
      cs_n_i = 1'b0;
      xfer({1'b1, addr, 3'b000});
      #480;
      // capture MISO while clocking the dummy byte
      for (b = 7; b >= 0; b--) begin
        mosi_i = 1'b0; #80; sclk_i = 1'b1; #40; rd_byte[b] = miso_o; #40; sclk_i = 1'b0; #80;
      end
      #240;
      cs_n_i = 1'b1;
      #800;
    end
  endtask

  task automatic wr(input logic [3:0] addr, input logic [7:0] data);
    begin
      cs_n_i = 1'b0;
      xfer({1'b0, addr, 3'b000});
      #480;
      xfer(data);
      #240;
      cs_n_i = 1'b1;
      #800;
    end
  endtask

  initial begin
    clk = 0; rst_n = 0; sclk_i = 0; cs_n_i = 1; mosi_i = 0;
    repeat (6) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    wr(REG_PAIR_LOG2, 8'h02);
    wr(REG_SETTLE,    8'h02);
    wr(REG_FREQ_SEL,  8'h00);  // selector 0 -> N=1 (10 MHz)
    wr(REG_CONV,      8'h01);

    $display("after config: rx_valids=%0d start_pulses=%0d", rx_valids, start_pulses);
    $display("  cfg regs in DUT: pair=%0d settle=%0d freq_sel=%0d div=%0d conv=%0d",
             dut.cfg_pair_log2_q, dut.cfg_settle_q, dut.cfg_freq_sel_q, dut.cfg_divider_w, dut.cfg_conv_q);

    // --- replicate the smoke test's error-injection sequence ---
    cs_n_i = 1'b0; xfer(8'h03); #480; xfer(8'h55); #240; cs_n_i = 1'b1; #800;
    $display("after invalid-cmd:  rx_valids=%0d rx_state=%0d flags[proto,addr,wr]=%b%b%b busy=%b",
             rx_valids, dut.rx_state_q, dut.status_protocol_err_q,
             dut.status_bad_addr_q, dut.status_illegal_wr_q, busy_o);
    rd(REG_STATUS);
    $display("  after STATUS read:  rx_state=%0d miso_byte=0x%02h flags=%b%b%b",
             dut.rx_state_q, rd_byte, dut.status_protocol_err_q,
             dut.status_bad_addr_q, dut.status_illegal_wr_q);
    wr(4'hF, 8'hAA);
    $display("after bad-addr:     rx_valids=%0d rx_state=%0d", rx_valids, dut.rx_state_q);
    wr(REG_STATUS, 8'h00);
    $display("after RO-write:     rx_valids=%0d rx_state=%0d", rx_valids, dut.rx_state_q);
    wr(REG_CTRL, 8'h80);
    $display("after clear-flags:  rx_valids=%0d rx_state=%0d pending_addr=%0d",
             rx_valids, dut.rx_state_q, dut.pending_addr_q);

    wr(REG_CTRL, 8'h01);
    $display("after CTRL start write: start_pulses=%0d rx_valids=%0d rx_state=%0d",
             start_pulses, rx_valids, dut.rx_state_q);
    $display("  fsm_state=%0d busy=%b done=%b",
             dut.u_core.u_measurement_fsm.state_q, busy_o, done_o);

    repeat (2000) @(posedge clk);
    $display("=== after 2000 more cycles ===");
    $display("  start_pulses=%0d done_pulses=%0d fsm_state=%0d busy=%b I=%0d Q=%0d",
             start_pulses, done_pulses,
             dut.u_core.u_measurement_fsm.state_q, busy_o, result_i_o, result_q_o);
    $finish;
  end
endmodule
