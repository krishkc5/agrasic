// -----------------------------------------------------------------------------
// Module: agriasic_digital_spi_top
// Purpose:
//   SPI-controlled wrapper that connects spi_slave + regfile + measurement core.
//
// Command format (1st byte):
//   bit[7]   : 1=READ, 0=WRITE
//   bit[6:3] : register address
//   bit[2:0] : reserved (write as 0)
//
// Write transaction:
//   Byte0 = command (RW=0), Byte1 = data
// Read transaction:
//   Byte0 = command (RW=1), Byte1 = dummy; response appears on MISO in Byte1
//
// Protocol responses:
//   0xA5 : write accepted (ACK)
//   0x5A : write rejected (NACK)
//   0xE1 : invalid command (reserved bits not zero)
//   0xE2 : invalid register address
// -----------------------------------------------------------------------------
module agriasic_digital_spi_top #(
  parameter int unsigned ADC_WIDTH = 8
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 sclk_i,
  input  logic                 cs_n_i,
  input  logic                 mosi_i,
  output logic                 miso_o,
  output logic                 miso_oe_o,
  output logic                 conv_start_o,
  output logic                 exc_drive_p_o,
  output logic                 exc_drive_n_o,
  output logic                 adc_enable_o,
  output logic                 adc_sample_o,
  output logic [ADC_WIDTH-1:0] adc_dac_o,
  input  logic                 adc_comp_i,
  output logic                 busy_o,
  output logic                 done_o,
  output logic [15:0]          result_o
);

  // Rev 4.3 Phase 2.1: rst_n is the raw, possibly-asynchronous chip pin.
  // Everything internal runs off rst_n_sync, released synchronously to clk.
  logic rst_n_sync;
  rst_sync u_rst_sync (
    .clk     (clk),
    .rst_n_i (rst_n),
    .rst_n_o (rst_n_sync)
  );

  localparam logic [3:0] REG_CTRL      = 4'h0;
  localparam logic [3:0] REG_PAIR_LOG2 = 4'h1;
  localparam logic [3:0] REG_SETTLE    = 4'h2;
  localparam logic [3:0] REG_DIVIDER   = 4'h3;
  localparam logic [3:0] REG_CONV      = 4'h4;
  localparam logic [3:0] REG_STATUS    = 4'h5;
  localparam logic [3:0] REG_RESULT_LO = 4'h6;
  localparam logic [3:0] REG_RESULT_HI = 4'h7;

  localparam logic [7:0] RSP_ACK        = 8'hA5;
  localparam logic [7:0] RSP_NACK       = 8'h5A;
  localparam logic [7:0] ERR_INV_CMD    = 8'hE1;
  localparam logic [7:0] ERR_BAD_ADDR   = 8'hE2;

  typedef enum logic [1:0] {
    RX_WAIT_CMD,
    RX_WAIT_WDATA,
    RX_WAIT_DROP
  } rx_state_t;

  rx_state_t rx_state_q;

  logic [7:0] spi_rx_data;
  logic       spi_rx_valid;
  logic [7:0] spi_tx_data;

  logic [3:0] rd_addr_q;
  logic [31:0] rd_data;
  logic [1:0]  stat_slot_q;

  logic        host_wr_en;
  logic [3:0]  host_wr_addr;
  logic [31:0] host_wr_data;

  logic        stat_wr_en;
  logic [3:0]  stat_wr_addr;
  logic [31:0] stat_wr_data;

  logic        rf_wr_en;
  logic [3:0]  rf_wr_addr;
  logic [31:0] rf_wr_data;

  logic [3:0] pending_addr_q;
  logic       pending_is_read_q;
  logic       pending_bad_addr_q;
  logic       pending_bad_cmd_q;

  logic start_pulse_q;

  logic [3:0]  cfg_pair_log2_q;
  logic [7:0]  cfg_settle_q;
  // Rev 4.3 Phase 4.2: internal datapath widened to 14 bits (GAP-1), but
  // REG_DIVIDER stays an 8-bit SPI window onto it for now -- only N=0..255
  // is host-reachable over SPI until Phase 6 formalizes how a wider N (or a
  // frequency-selector index) is encoded into the 2-byte SPI protocol. This
  // keeps host-visible behavior identical to pre-Phase-4 while the RTL
  // itself is honestly 14-bit-wide and ready for Phase 6 to extend.
  logic [13:0] cfg_divider_q;
  logic [7:0]  cfg_conv_q;

  logic core_done;
  logic status_done_q;

  logic status_protocol_err_q;
  logic status_bad_addr_q;
  logic status_illegal_wr_q;

  logic [7:0] status_byte;

  function automatic logic is_valid_addr(input logic [3:0] addr);
    begin
      is_valid_addr = (addr <= REG_RESULT_HI);
    end
  endfunction

  function automatic logic is_read_only_addr(input logic [3:0] addr);
    begin
      is_read_only_addr = (addr == REG_STATUS) || (addr == REG_RESULT_LO) || (addr == REG_RESULT_HI);
    end
  endfunction

  function automatic logic [7:0] read_byte_from_addr(input logic [3:0] addr);
    begin
      unique case (addr)
        REG_PAIR_LOG2: read_byte_from_addr = {4'd0, cfg_pair_log2_q};
        REG_SETTLE:    read_byte_from_addr = cfg_settle_q;
        REG_DIVIDER:   read_byte_from_addr = cfg_divider_q[7:0];  // low byte only, see field decl
        REG_CONV:      read_byte_from_addr = cfg_conv_q;
        REG_STATUS:    read_byte_from_addr = status_byte;
        REG_RESULT_LO: read_byte_from_addr = result_o[7:0];
        REG_RESULT_HI: read_byte_from_addr = result_o[15:8];
        default:       read_byte_from_addr = rd_data[7:0];
      endcase
    end
  endfunction

  // Sticky done.
  //
  // The measurement FSM's start is a single-cycle pulse, so the FSM leaves its
  // DONE state immediately and done_o is asserted for exactly ONE core cycle.
  // A SPI host polling STATUS needs many cycles per transaction and could never
  // observe that, so completion is latched here and held until the next start.
  always_ff @(posedge clk or negedge rst_n_sync) begin
    if (!rst_n_sync) begin
      status_done_q <= 1'b0;
    end else if (start_pulse_q) begin
      status_done_q <= 1'b0;
    end else if (core_done) begin
      status_done_q <= 1'b1;
    end
  end

  assign done_o = status_done_q;

  assign status_byte = {
    status_protocol_err_q,
    status_bad_addr_q,
    status_illegal_wr_q,
    3'b000,
    status_done_q,
    busy_o
  };

  spi_slave #(
    .DATA_W(8)
  ) u_spi_slave (
    .clk       (clk),
    .rst_n     (rst_n_sync),
    .sclk_i    (sclk_i),
    .cs_n_i    (cs_n_i),
    .mosi_i    (mosi_i),
    .miso_o    (miso_o),
    .miso_oe_o (miso_oe_o),
    .rx_data_o (spi_rx_data),
    .rx_valid_o(spi_rx_valid),
    .tx_data_i (spi_tx_data)
  );

  regfile #(
    .AW(4),
    .DW(32)
  ) u_regfile (
    .clk      (clk),
    .rst_n    (rst_n_sync),
    .wr_en_i  (rf_wr_en),
    .wr_addr_i(rf_wr_addr),
    .wr_data_i(rf_wr_data),
    .rd_addr_i(rd_addr_q),
    .rd_data_o(rd_data)
  );

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) u_core (
    .clk                (clk),
    .rst_n              (rst_n_sync),
    .start              (start_pulse_q),
    .cfg_pair_log2_i    (cfg_pair_log2_q),
    .cfg_settle_cycles_i(cfg_settle_q),
    .cfg_exc_divider_i  (cfg_divider_q),
    .cfg_conv_cycles_i  (cfg_conv_q),
    .conv_start_o       (conv_start_o),
    .exc_drive_p_o      (exc_drive_p_o),
    .exc_drive_n_o      (exc_drive_n_o),
    .adc_enable_o       (adc_enable_o),
    .adc_sample_o       (adc_sample_o),
    .adc_dac_o          (adc_dac_o),
    .adc_comp_i         (adc_comp_i),
    .busy_o             (busy_o),
    .done_o             (core_done),
    .result_o           (result_o)
  );

  // Continuous status/result mirror writes into regfile for SPI visibility.
  always_comb begin
    stat_wr_en   = 1'b1;
    unique case (stat_slot_q)
      2'd0: begin
        stat_wr_addr = REG_STATUS;
        stat_wr_data = {24'd0, status_byte};
      end
      2'd1: begin
        stat_wr_addr = REG_RESULT_LO;
        stat_wr_data = {24'd0, result_o[7:0]};
      end
      default: begin
        stat_wr_addr = REG_RESULT_HI;
        stat_wr_data = {24'd0, result_o[15:8]};
      end
    endcase
  end

  // Write arbiter: status/result mirror has priority over host writes.
  always_comb begin
    rf_wr_en   = 1'b0;
    rf_wr_addr = 4'd0;
    rf_wr_data = 32'd0;

    if (stat_wr_en) begin
      rf_wr_en   = 1'b1;
      rf_wr_addr = stat_wr_addr;
      rf_wr_data = stat_wr_data;
    end

    if (host_wr_en) begin
      rf_wr_en   = 1'b1;
      rf_wr_addr = host_wr_addr;
      rf_wr_data = host_wr_data;
    end
  end

  always_ff @(posedge clk or negedge rst_n_sync) begin
    if (!rst_n_sync) begin
      rx_state_q         <= RX_WAIT_CMD;
      pending_addr_q     <= 4'd0;
      pending_is_read_q  <= 1'b0;
      pending_bad_addr_q <= 1'b0;
      pending_bad_cmd_q  <= 1'b0;
      rd_addr_q          <= 4'd0;
      spi_tx_data        <= 8'd0;
      host_wr_en         <= 1'b0;
      host_wr_addr       <= 4'd0;
      host_wr_data       <= 32'd0;
      stat_slot_q        <= 2'd0;
      start_pulse_q      <= 1'b0;
      cfg_pair_log2_q    <= 4'd2;
      cfg_settle_q       <= 8'd2;
      cfg_divider_q      <= 14'd0;
      cfg_conv_q         <= 8'd1;
      status_protocol_err_q <= 1'b0;
      status_bad_addr_q     <= 1'b0;
      status_illegal_wr_q   <= 1'b0;
    end else begin
      host_wr_en    <= 1'b0;
      start_pulse_q <= 1'b0;
      stat_slot_q   <= stat_slot_q + 2'd1;

      if (spi_rx_valid) begin
        unique case (rx_state_q)
          RX_WAIT_CMD: begin
            pending_is_read_q <= spi_rx_data[7];
            pending_addr_q    <= spi_rx_data[6:3];
            pending_bad_addr_q <= !is_valid_addr(spi_rx_data[6:3]);
            pending_bad_cmd_q  <= (spi_rx_data[2:0] != 3'b000);
            rd_addr_q         <= spi_rx_data[6:3];

            if (spi_rx_data[2:0] != 3'b000) begin
              status_protocol_err_q <= 1'b1;
              spi_tx_data <= ERR_INV_CMD;
              // Keep command framing deterministic: consume Byte1 before
              // accepting the next command.
              rx_state_q  <= RX_WAIT_DROP;
            end else if (!is_valid_addr(spi_rx_data[6:3])) begin
              status_bad_addr_q <= 1'b1;
              spi_tx_data <= ERR_BAD_ADDR;
              // Keep command framing deterministic: consume Byte1 before
              // accepting the next command.
              rx_state_q  <= RX_WAIT_DROP;
            end else if (spi_rx_data[7]) begin
              // READ: make requested data available for the next SPI byte.
              spi_tx_data <= read_byte_from_addr(spi_rx_data[6:3]);
              // A read is a two-byte transaction: the host clocks a dummy byte
              // to shift the response out on MISO. That dummy must be consumed,
              // otherwise it is decoded as the next command (0x00 looks like a
              // write to REG_CTRL), which then swallows the following
              // transaction's command byte as its payload and desynchronizes
              // the framing permanently.
              rx_state_q  <= RX_WAIT_DROP;
            end else begin
              // WRITE: wait for one payload data byte.
              rx_state_q <= RX_WAIT_WDATA;
            end
          end

          RX_WAIT_WDATA: begin
            rx_state_q   <= RX_WAIT_CMD;
            if (pending_bad_cmd_q) begin
              status_protocol_err_q <= 1'b1;
              spi_tx_data <= ERR_INV_CMD;
            end else if (pending_bad_addr_q) begin
              status_bad_addr_q <= 1'b1;
              spi_tx_data <= ERR_BAD_ADDR;
            end else if (is_read_only_addr(pending_addr_q)) begin
              status_illegal_wr_q <= 1'b1;
              spi_tx_data <= RSP_NACK;
            end else begin
              host_wr_en   <= 1'b1;
              host_wr_addr <= pending_addr_q;
              host_wr_data <= {24'd0, spi_rx_data};
              spi_tx_data  <= RSP_ACK;

              unique case (pending_addr_q)
                REG_CTRL: begin
                  // Start bit is write-one-to-pulse. Bit7 clears sticky errors.
                  if (spi_rx_data[7]) begin
                    status_protocol_err_q <= 1'b0;
                    status_bad_addr_q     <= 1'b0;
                    status_illegal_wr_q   <= 1'b0;
                  end
                  if (spi_rx_data[0]) begin
                    start_pulse_q <= 1'b1;
                  end
                end
                REG_PAIR_LOG2: cfg_pair_log2_q <= spi_rx_data[3:0];
                REG_SETTLE:    cfg_settle_q    <= spi_rx_data;
                REG_DIVIDER:   cfg_divider_q   <= {6'd0, spi_rx_data};  // zero-extend, see field decl
                REG_CONV:      cfg_conv_q      <= spi_rx_data;
                default: begin
                end
              endcase
            end

            pending_bad_addr_q <= 1'b0;
            pending_bad_cmd_q  <= 1'b0;
          end

          RX_WAIT_DROP: begin
            rx_state_q <= RX_WAIT_CMD;
          end

          default: begin
            rx_state_q <= RX_WAIT_CMD;
          end
        endcase
      end
    end
  end

endmodule
