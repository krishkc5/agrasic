`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_agriasic_digital_spi_top
// Purpose:
//   Smoke test for SPI-controlled wrapper.
//
// Coverage in this test:
//   - Writes config registers through SPI (Rev 4.3 Phase 6 map: REG_FREQ_SEL
//     selector encoding, not raw N).
//   - Issues start command through SPI.
//   - Drives ADC codes according to the I/Q sample phase during conversions.
//   - Reads both result channels back through the Phase 6 indexed readout
//     (REG_RESULT_IDX/REG_RESULT_DATA), checks expected values, auto-
//     increment, and that reserved indices read as zero.
//   - Reads REG_ID and checks the fixed design identifier.
// -----------------------------------------------------------------------------
module tb_agriasic_digital_spi_top;
  localparam int unsigned ADC_WIDTH = 8;
  // Same four-target I/Q model as tb_agriasic_digital_top (section 6.11):
  // D(0)=220, D(180)=100 -> I = 4*120 = 480; D(90)=170, D(270)=90 -> Q = 4*80 = 320.
  localparam logic signed [15:0] EXPECTED_I = 16'sd480;
  localparam logic signed [15:0] EXPECTED_Q = 16'sd320;

  // Rev 4.3 Phase 6 register map -- see agriasic_digital_spi_top.sv's header
  // for the full map and the REG_RESULT_IDX/DATA index mapping.
  localparam logic [3:0] REG_CTRL         = 4'h0;
  localparam logic [3:0] REG_PAIR_LOG2    = 4'h1;
  localparam logic [3:0] REG_SETTLE       = 4'h2;
  localparam logic [3:0] REG_FREQ_SEL     = 4'h3;
  localparam logic [3:0] REG_PHASE_IDX    = 4'h4;
  localparam logic [3:0] REG_CONV         = 4'h5;
  localparam logic [3:0] REG_STATUS       = 4'h6;
  localparam logic [3:0] REG_RESULT_IDX   = 4'h7;
  localparam logic [3:0] REG_RESULT_DATA  = 4'h8;
  localparam logic [3:0] REG_ID           = 4'h9;
  localparam logic [3:0] REG_INVALID      = 4'hF;

  localparam logic [7:0] DESIGN_ID = 8'h43;

  // Result byte vector indices (REG_RESULT_DATA), matching the DUT header.
  localparam logic [3:0] RIDX_I_LO = 4'd0;
  localparam logic [3:0] RIDX_I_HI = 4'd1;
  localparam logic [3:0] RIDX_Q_LO = 4'd2;
  localparam logic [3:0] RIDX_Q_HI = 4'd3;

  logic clk;
  logic rst_n;
  logic sclk_i;
  logic cs_n_i;
  logic mosi_i;
  logic miso_o;
  logic miso_oe_o;
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

  logic [7:0] status_byte;
  logic [7:0] result_i_lo;
  logic [7:0] result_i_hi;
  logic [7:0] result_q_lo;
  logic [7:0] result_q_hi;
  logic [7:0] cmd_phase_rx;
  logic [7:0] idx_readback;
  logic [7:0] reserved_byte;
  logic [7:0] id_byte;
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
    .miso_oe_o(miso_oe_o),
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

  // Behavioral comparator model for the Rev 4.3 SAR bit-trial interface. See
  // sar_controller's header for the adc_comp_i convention this implements.
  // Rev 4.3 Phase 5: four distinct targets, one per I/Q sample phase, keyed
  // on measurement_fsm's own state rather than phase_index or drive polarity
  // -- see tb_agriasic_digital_top's header comment on this same model for
  // why (the one-cycle sample-accept lag inside sar_controller means
  // phase_index has already ticked past its nominal value by the time
  // adc_sample_o actually fires at N=1).
  //   3=S_SAMPLE_0 5=S_SAMPLE_180 8=S_SAMPLE_90 10=S_SAMPLE_270
  logic [ADC_WIDTH-1:0] adc_target_held_q;
  always_ff @(posedge clk) begin
    if (adc_sample_o) begin
      unique case (4'(dut.u_core.u_measurement_fsm.state_q))
        4'd3:  adc_target_held_q <= 8'd220;  // S_SAMPLE_0:   D(0)
        4'd8:  adc_target_held_q <= 8'd170;  // S_SAMPLE_90:  D(90)
        4'd5:  adc_target_held_q <= 8'd100;  // S_SAMPLE_180: D(180)
        4'd10: adc_target_held_q <= 8'd90;   // S_SAMPLE_270: D(270)
        default: begin end
      endcase
    end
  end
  assign adc_comp_i = (adc_target_held_q >= adc_dac_o);

  task automatic spi_transfer_byte(
    input  logic [7:0] tx,
    output logic [7:0] rx
  );
    int b;
    begin
      rx = 8'h00;
      for (b = 7; b >= 0; b--) begin
        mosi_i = tx[b];
        #80;
        sclk_i = 1'b1;
        #40;
        rx[b] = miso_o;
        #40;
        sclk_i = 1'b0;
        #80;
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
      #480;
      spi_transfer_byte(data, throw_away);
      #240;
      cs_n_i = 1'b1;
      #800;
    end
  endtask

  task automatic spi_write_cmd_raw(input logic [7:0] cmd, input logic [7:0] data);
    logic [7:0] throw_away;
    begin
      cs_n_i = 1'b0;
      spi_transfer_byte(cmd, throw_away);
      #480;
      spi_transfer_byte(data, throw_away);
      #240;
      cs_n_i = 1'b1;
      #800;
    end
  endtask

  // Returns first-byte MISO stream while issuing a command byte.
  task automatic spi_capture_cmd_phase(input logic [7:0] cmd, output logic [7:0] rx_cmd_phase);
    logic [7:0] throw_away;
    begin
      cs_n_i = 1'b0;
      spi_transfer_byte(cmd, rx_cmd_phase);
      #480;
      spi_transfer_byte(8'h00, throw_away);
      #240;
      cs_n_i = 1'b1;
      #800;
    end
  endtask

  task automatic spi_read_reg(input logic [3:0] addr, output logic [7:0] data);
    logic [7:0] throw_away;
    logic [7:0] cmd;
    begin
      cmd = {1'b1, addr, 3'b000};
      cs_n_i = 1'b0;
      spi_transfer_byte(cmd, throw_away);
      #480;
      spi_transfer_byte(8'h00, data);
      #240;
      cs_n_i = 1'b1;
      #800;
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

  // Rev 4.3 DR-021: MISO output enable must track cs_n exactly, once
  // synchronized. Phase 3 moved cs_n through a 2FF synchronizer inside
  // spi_slave, so miso_oe_o now lags the raw testbench-driven cs_n_i by that
  // latency -- checking against the internal synchronized signal (which is
  // what miso_oe_o is actually, combinationally, derived from) is the
  // correct comparison, not a relaxation of the check.
  property p_miso_oe_tracks_cs;
    @(posedge clk) disable iff (!rst_n)
      miso_oe_o == !dut.u_spi_slave.cs_n_sync_q;
  endproperty

  assert property (p_conv_start_single_cycle)
    else $error("ASSERT_FAIL: conv_start_o must be single-cycle pulse");

  assert property (p_done_not_busy)
    else $error("ASSERT_FAIL: done_o and busy_o cannot be high together");

  assert property (p_miso_oe_tracks_cs)
    else $error("ASSERT_FAIL: miso_oe_o must equal ~cs_n_i");

  initial begin
    clk      = 1'b0;
    rst_n    = 1'b0;
    sclk_i   = 1'b0;
    cs_n_i   = 1'b1;
    mosi_i   = 1'b0;

    repeat (6) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Program core behavior: 4 pairs, settle=2, freq_sel=0 (10 MHz, N=1), conv=1
    spi_write_reg(REG_PAIR_LOG2, 8'h02);
    spi_write_reg(REG_SETTLE,    8'h02);
    spi_write_reg(REG_FREQ_SEL,  8'h00);
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

    // Rev 4.3 Phase 5: 4 conversions/pair now (was 2), so the timeout budget
    // needs roughly double the pre-Phase-5 headroom.
    wait_cycles = 0;
    while (!done_o && wait_cycles < 2000) begin
      @(posedge clk);
      wait_cycles++;
    end

    if (!done_o) begin
      $error("SPI_TOP_TIMEOUT: done_o did not assert");
      $finish;
    end

    // Read back status via SPI.
    spi_read_reg(REG_STATUS, status_byte);

    // Rev 4.3 Phase 6: indexed result readout. Set REG_RESULT_IDX to 0, then
    // read REG_RESULT_DATA four times in a row -- each read should return
    // I_lo/I_hi/Q_lo/Q_hi in that order AND auto-increment the pointer, with
    // no separate index write needed between reads.
    spi_write_reg(REG_RESULT_IDX, {4'd0, RIDX_I_LO});
    spi_read_reg(REG_RESULT_DATA, result_i_lo);
    spi_read_reg(REG_RESULT_DATA, result_i_hi);
    spi_read_reg(REG_RESULT_DATA, result_q_lo);
    spi_read_reg(REG_RESULT_DATA, result_q_hi);

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

    if ($signed({result_i_hi, result_i_lo}) !== EXPECTED_I) begin
      $error(
        "SPI_TOP_RESULT_FAIL: expected I=%0d got=%0d (hi=0x%0h lo=0x%0h)",
        EXPECTED_I,
        $signed({result_i_hi, result_i_lo}),
        result_i_hi,
        result_i_lo
      );
      $finish;
    end

    if ($signed({result_q_hi, result_q_lo}) !== EXPECTED_Q) begin
      $error(
        "SPI_TOP_RESULT_FAIL: expected Q=%0d got=%0d (hi=0x%0h lo=0x%0h)",
        EXPECTED_Q,
        $signed({result_q_hi, result_q_lo}),
        result_q_hi,
        result_q_lo
      );
      $finish;
    end

    // Rev 4.3 Phase 6: after four REG_RESULT_DATA reads starting from index
    // 0, the pointer should have auto-incremented to 4 -- verify by reading
    // REG_RESULT_IDX directly (a plain register read, no auto-increment on
    // this address).
    spi_read_reg(REG_RESULT_IDX, idx_readback);
    if (idx_readback !== 8'd4) begin
      $error("SPI_TOP_RESULT_IDX_FAIL: expected pointer=4 after 4 data reads, got=%0d",
             idx_readback);
      $finish;
    end

    // Index 4 is reserved (frequency points 1/2 and temperature, not built
    // yet) and must read as zero, not garbage or leftover I/Q data.
    spi_read_reg(REG_RESULT_DATA, reserved_byte);
    if (reserved_byte !== 8'd0) begin
      $error("SPI_TOP_RESERVED_IDX_FAIL: expected reserved index 4 to read 0, got=0x%0h",
             reserved_byte);
      $finish;
    end

    // REG_ID must return the fixed design/revision identifier.
    spi_read_reg(REG_ID, id_byte);
    if (id_byte !== DESIGN_ID) begin
      $error("SPI_TOP_ID_FAIL: expected REG_ID=0x%0h got=0x%0h", DESIGN_ID, id_byte);
      $finish;
    end

    // Rev 4.3 Phase 6: REG_STATUS overrange bit. pair_log2=7 (> 6) is
    // silently clamped to M=64 in measurement_fsm; writing it here (post-run,
    // core idle) must set STATUS bit4 without disturbing anything else.
    spi_write_reg(REG_PAIR_LOG2, 8'h07);
    spi_read_reg(REG_STATUS, status_byte);
    if (status_byte[4] !== 1'b1) begin
      $error("SPI_TOP_OVERRANGE_FAIL: expected overrange bit set for pair_log2=7, got status=0x%0h",
             status_byte);
      $finish;
    end
    spi_write_reg(REG_PAIR_LOG2, 8'h02);
    spi_read_reg(REG_STATUS, status_byte);
    if (status_byte[4] !== 1'b0) begin
      $error("SPI_TOP_OVERRANGE_FAIL: expected overrange bit clear after pair_log2=2, got status=0x%0h",
             status_byte);
      $finish;
    end

    $display("SPI_TOP_SMOKE_PASS: status=0x%0h I=%0d Q=%0d ID=0x%0h", status_byte,
             $signed({result_i_hi, result_i_lo}), $signed({result_q_hi, result_q_lo}),
             id_byte);
    $finish;
  end
endmodule
