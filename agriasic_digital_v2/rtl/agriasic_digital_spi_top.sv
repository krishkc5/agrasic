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
//
// Rev 4.3 Phase 6 register map (replaces the Phase 5 interim direct result
// registers -- see the MAS section 7.1/7.2 for the full reconciliation):
//   0x0 REG_CTRL       RW  bit0=start, bit7=clear sticky errors
//   0x1 REG_PAIR_LOG2  RW  M = 2^value
//   0x2 REG_SETTLE     RW  excitation periods to wait after start
//   0x3 REG_FREQ_SEL   RW  2-bit selector 0/1/2 -> N=1/100/10000 (10 MHz/
//                          100 kHz/1 kHz). Replaces the raw-N REG_DIVIDER:
//                          a selector is the only way to reach the 1 kHz
//                          point (N=10000, needs 14 bits) through a single
//                          SPI byte without widening the 2-byte protocol.
//                          See GAP-1, now closed on the SPI side.
//   0x4 REG_PHASE_IDX  RW  Present in the register map, per the baseline
//                          design doc, but NOT WIRED to anything -- see the
//                          "REG_PHASE_IDX" note below and MAS GAP-10.
//                          Writes are stored and read back; they have no
//                          effect on measurement_fsm.
//   0x5 REG_CONV       RW  SAR comparator regeneration wait, per bit trial
//   0x6 REG_STATUS     RO  bit7 protocol_err, bit6 bad_addr, bit5 illegal_wr,
//                          bit4 overrange (pair_log2 > 6, clamped to 64),
//                          bit1 done, bit0 busy
//   0x7 REG_RESULT_IDX RW  Pointer into the result byte vector (0-15,
//                          auto-increments on each REG_RESULT_DATA read)
//   0x8 REG_RESULT_DATA RO Byte at the current index -- see the mapping note
//                          below
//   0x9 REG_ID         RO  Fixed design/revision identifier, 8'h43
//
// REG_RESULT_IDX/REG_RESULT_DATA (Phase 6's headline feature): the target
// result set is I/Q for three frequency points plus temperature, 13 bytes
// (MAS section 7.2). Only one frequency point's worth of real data exists
// today (Phase 7's sweep and any temperature sensing are not built), so the
// mapping is:
//   idx 0: result_i_o[7:0]    idx 1: result_i_o[15:8]
//   idx 2: result_q_o[7:0]    idx 3: result_q_o[15:8]
//   idx 4-15: reserved, reads as 0 (frequency points 1/2 and temperature,
//             once Phase 7 exists to populate them; 13-15 are unused padding
//             beyond the 13-byte result set, a consequence of using a plain
//             4-bit wraparound counter for idx_q rather than a mod-13
//             counter -- cheaper, and the extra 3 addresses cost nothing)
//
// REG_PHASE_IDX note: the baseline design doc lists this as "phase index
// into the 16-state counter" but does not say what value a host would
// actually want there, given measurement_fsm's I/Q sampling requires four
// FIXED, 90-degree-spaced phase points (section 6.1) -- there is no
// "single arbitrary phase" a host could sensibly select instead. The most
// plausible reading is a phase OFFSET that shifts all four sample points
// together (a calibration trim for excitation-path propagation delay), but
// that is an interpretation, not a specification, and building RTL against
// a guessed semantic for a register that will be silicon-bound is worse
// than leaving it honestly unimplemented. The address is reserved and
// accepts writes so host software probing the documented map doesn't get
// an unexpected NACK, but it does nothing. See MAS GAP-10: get the actual
// intended semantics from whoever specified this register before wiring
// it to anything.
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
  output logic signed [15:0]   result_i_o,  // Rev 4.3 Phase 5: I channel
  output logic signed [15:0]   result_q_o   // Rev 4.3 Phase 5: Q channel
);

  // Rev 4.3 Phase 2.1: rst_n is the raw, possibly-asynchronous chip pin.
  // Everything internal runs off rst_n_sync, released synchronously to clk.
  logic rst_n_sync;
  rst_sync u_rst_sync (
    .clk     (clk),
    .rst_n_i (rst_n),
    .rst_n_o (rst_n_sync)
  );

  localparam logic [3:0] REG_CTRL        = 4'h0;
  localparam logic [3:0] REG_PAIR_LOG2   = 4'h1;
  localparam logic [3:0] REG_SETTLE      = 4'h2;
  localparam logic [3:0] REG_FREQ_SEL    = 4'h3;
  localparam logic [3:0] REG_PHASE_IDX   = 4'h4;
  localparam logic [3:0] REG_CONV        = 4'h5;
  localparam logic [3:0] REG_STATUS      = 4'h6;
  localparam logic [3:0] REG_RESULT_IDX  = 4'h7;
  localparam logic [3:0] REG_RESULT_DATA = 4'h8;
  localparam logic [3:0] REG_ID          = 4'h9;

  localparam logic [7:0] DESIGN_ID       = 8'h43;  // "Rev 4.3", arbitrary but fixed

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
  logic [2:0]  stat_slot_q;

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
  logic       pending_bad_addr_q;
  logic       pending_bad_cmd_q;

  logic start_pulse_q;

  logic [3:0]  cfg_pair_log2_q;
  logic [7:0]  cfg_settle_q;
  logic [1:0]  cfg_freq_sel_q;   // Rev 4.3 Phase 6: selector, not raw N
  logic [7:0]  cfg_phase_idx_q;  // Rev 4.3 Phase 6: stored, not wired (see header)
  logic [7:0]  cfg_conv_q;
  logic [3:0]  result_idx_q;    // Rev 4.3 Phase 6: REG_RESULT_IDX pointer

  // cfg_freq_sel_q selects one of three presets exactly, at f_clk=160 MHz:
  // f_exc = f_clk/(16*N) -> N=1 gives 10 MHz, N=100 gives 100 kHz,
  // N=10000 gives 1 kHz (the same three values GAP-1 derives). This is a
  // combinational lookup, not a stored register -- cfg_divider_w is fully
  // determined by cfg_freq_sel_q, so there is nothing to keep in sync.
  logic [13:0] cfg_divider_w;
  always_comb begin
    unique case (cfg_freq_sel_q)
      2'd0:    cfg_divider_w = 14'd1;      // 10 MHz
      2'd1:    cfg_divider_w = 14'd100;    // 100 kHz
      2'd2:    cfg_divider_w = 14'd10000;  // 1 kHz
      default: cfg_divider_w = 14'd1;      // reserved selector value 3: default to fastest
    endcase
  end

  logic core_done;
  logic status_done_q;

  logic status_protocol_err_q;
  logic status_bad_addr_q;
  logic status_illegal_wr_q;
  logic status_overrange_w;

  logic [7:0] status_byte;

  // Rev 4.3 Phase 6: pair_log2 > 6 is silently clamped to M=64 in
  // measurement_fsm (section 9.3's accumulator-width bound); this makes that
  // clamp host-visible instead of silent, per the design doc's REG_STATUS
  // "overrange" bit.
  assign status_overrange_w = (cfg_pair_log2_q > 4'd6);

  function automatic logic is_valid_addr(input logic [3:0] addr);
    begin
      is_valid_addr = (addr <= REG_ID);
    end
  endfunction

  function automatic logic is_read_only_addr(input logic [3:0] addr);
    begin
      is_read_only_addr = (addr == REG_STATUS) || (addr == REG_RESULT_DATA) ||
                           (addr == REG_ID);
    end
  endfunction

  // Rev 4.3 Phase 6: the result byte vector. See the header comment for the
  // index mapping -- only 0-3 carry real data today.
  function automatic logic [7:0] result_byte_at(input logic [3:0] idx);
    begin
      unique case (idx)
        4'd0:    result_byte_at = result_i_o[7:0];
        4'd1:    result_byte_at = result_i_o[15:8];
        4'd2:    result_byte_at = result_q_o[7:0];
        4'd3:    result_byte_at = result_q_o[15:8];
        default: result_byte_at = 8'd0;  // reserved: future freq points + temperature
      endcase
    end
  endfunction

  function automatic logic [7:0] read_byte_from_addr(input logic [3:0] addr);
    begin
      unique case (addr)
        REG_PAIR_LOG2:   read_byte_from_addr = {4'd0, cfg_pair_log2_q};
        REG_SETTLE:      read_byte_from_addr = cfg_settle_q;
        REG_FREQ_SEL:    read_byte_from_addr = {6'd0, cfg_freq_sel_q};
        REG_PHASE_IDX:   read_byte_from_addr = cfg_phase_idx_q;
        REG_CONV:        read_byte_from_addr = cfg_conv_q;
        REG_STATUS:      read_byte_from_addr = status_byte;
        REG_RESULT_IDX:  read_byte_from_addr = {4'd0, result_idx_q};
        REG_RESULT_DATA: read_byte_from_addr = result_byte_at(result_idx_q);
        REG_ID:          read_byte_from_addr = DESIGN_ID;
        default:         read_byte_from_addr = rd_data[7:0];
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
    status_overrange_w,
    2'b00,
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
    .cfg_exc_divider_i  (cfg_divider_w),
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
    .result_i_o         (result_i_o),
    .result_q_o         (result_q_o)
  );

  // Continuous status mirror write into regfile for SPI visibility. This is
  // non-load-bearing for correctness (read_byte_from_addr handles every
  // valid address directly and never falls through to rd_data), kept as a
  // single slot -- see the Phase 5/6 history in the MAS for why this mirror
  // does not need to track the result registers.
  always_comb begin
    stat_wr_en   = 1'b1;
    stat_wr_addr = REG_STATUS;
    stat_wr_data = {24'd0, status_byte};
  end

  // Write arbiter: status mirror has priority over host writes.
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
      pending_bad_addr_q <= 1'b0;
      pending_bad_cmd_q  <= 1'b0;
      rd_addr_q          <= 4'd0;
      spi_tx_data        <= 8'd0;
      host_wr_en         <= 1'b0;
      host_wr_addr       <= 4'd0;
      host_wr_data       <= 32'd0;
      stat_slot_q        <= 3'd0;
      start_pulse_q      <= 1'b0;
      cfg_pair_log2_q    <= 4'd2;
      cfg_settle_q       <= 8'd2;
      cfg_freq_sel_q     <= 2'd0;
      cfg_phase_idx_q    <= 8'd0;
      cfg_conv_q         <= 8'd1;
      result_idx_q       <= 4'd0;
      status_protocol_err_q <= 1'b0;
      status_bad_addr_q     <= 1'b0;
      status_illegal_wr_q   <= 1'b0;
    end else begin
      host_wr_en    <= 1'b0;
      start_pulse_q <= 1'b0;
      stat_slot_q   <= stat_slot_q + 3'd1;

      if (spi_rx_valid) begin
        unique case (rx_state_q)
          RX_WAIT_CMD: begin
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
              // Rev 4.3 Phase 6: reading REG_RESULT_DATA auto-increments the
              // pointer, wrapping naturally at the 4-bit boundary (16).
              if (spi_rx_data[6:3] == REG_RESULT_DATA) begin
                result_idx_q <= result_idx_q + 4'd1;
              end
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
                REG_PAIR_LOG2:  cfg_pair_log2_q <= spi_rx_data[3:0];
                REG_SETTLE:     cfg_settle_q    <= spi_rx_data;
                REG_FREQ_SEL:   cfg_freq_sel_q  <= spi_rx_data[1:0];
                REG_PHASE_IDX:  cfg_phase_idx_q <= spi_rx_data;  // stored, not wired -- see header
                REG_CONV:       cfg_conv_q      <= spi_rx_data;
                REG_RESULT_IDX: result_idx_q    <= spi_rx_data[3:0];
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
