// -----------------------------------------------------------------------------
// Module: spi_slave
// Purpose:
//   SPI mode-0 byte-serial slave (CPOL=0, CPHA=0) for control-plane exchange.
//
// Functionality:
//   - Captures MOSI on rising edges of sclk_i while cs_n_i is low.
//   - Drives MISO from the falling edge, as SPI mode 0 requires.
//   - Emits one rx_valid_o pulse in clk domain for each completed byte.
//
// TX timing (this is the subtle part):
//   The response byte is produced in the CORE clock domain, several cycles after
//   a byte completes, because rx_valid_o crosses in through a toggle
//   synchronizer. An earlier version reloaded the TX shift register on the same
//   SCLK edge that STARTED that crossing, so it always latched the previous
//   response -- every read returned the prior transaction's byte.
//
//   Instead, the first bit of each byte is driven combinationally from
//   tx_data_i, which has had the entire inter-byte gap to settle, and only the
//   remaining seven bits come from the shift register (loaded on the first
//   falling edge of the byte). MISO may move while SCLK is idle between bytes;
//   that is harmless because the host samples only on rising edges.
//
// Host requirement:
//   Leave an inter-byte gap long enough for the CDC to settle (a few core
//   clocks). The command/data byte gap used by the register protocol is ample.
//
// Integration intent:
//   Address decoding and register mapping remain top-level responsibilities.
// -----------------------------------------------------------------------------
module spi_slave #(
  parameter int unsigned DATA_W = 8
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              sclk_i,
  input  logic              cs_n_i,
  input  logic              mosi_i,
  output logic              miso_o,
  output logic [DATA_W-1:0] rx_data_o,
  output logic              rx_valid_o,
  input  logic [DATA_W-1:0] tx_data_i
);

  logic [DATA_W-1:0] rx_shift_q;
  logic [DATA_W-1:0] tx_shift_q;
  logic [DATA_W-1:0] rx_data_sclk_q;
  logic [2:0]        bit_cnt_q;
  logic              rx_done_tgl_q;
  logic              tx_first_q;

  logic rx_done_meta_q;
  logic rx_done_sync_q;
  logic rx_done_sync_qq;

  // ---------------------------------------------------------------------------
  // RX: sample MOSI on the rising edge (mode 0).
  // ---------------------------------------------------------------------------
  always_ff @(posedge sclk_i or posedge cs_n_i or negedge rst_n) begin
    if (!rst_n) begin
      rx_shift_q     <= '0;
      rx_data_sclk_q <= '0;
      bit_cnt_q      <= 3'd0;
      rx_done_tgl_q  <= 1'b0;
    end else if (cs_n_i) begin
      bit_cnt_q <= 3'd0;
    end else begin
      rx_shift_q <= {rx_shift_q[DATA_W-2:0], mosi_i};

      if (bit_cnt_q == 3'd7) begin
        bit_cnt_q      <= 3'd0;
        rx_data_sclk_q <= {rx_shift_q[DATA_W-2:0], mosi_i};
        rx_done_tgl_q  <= ~rx_done_tgl_q;
      end else begin
        bit_cnt_q <= bit_cnt_q + 3'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // TX: change MISO on the falling edge (mode 0).
  //
  // tx_first_q marks "the next bit out is bit 7 of a fresh byte". It is set on
  // the falling edge that closes a byte (bit_cnt_q has wrapped to 0 by then) and
  // cleared on the first falling edge of the next byte, where the remaining
  // seven bits are latched from tx_data_i.
  // ---------------------------------------------------------------------------
  always_ff @(negedge sclk_i or posedge cs_n_i or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift_q <= '0;
      tx_first_q <= 1'b1;
    end else if (cs_n_i) begin
      tx_shift_q <= '0;
      tx_first_q <= 1'b1;
    end else if (bit_cnt_q == 3'd0) begin
      // Falling edge that closes a byte: the next byte starts from tx_data_i
      // again, which by then carries the freshly decoded response.
      tx_first_q <= 1'b1;
    end else if (tx_first_q) begin
      // First falling edge of a byte: latch the remaining seven bits.
      tx_shift_q <= {tx_data_i[DATA_W-2:0], 1'b0};
      tx_first_q <= 1'b0;
    end else begin
      tx_shift_q <= {tx_shift_q[DATA_W-2:0], 1'b0};
    end
  end

  // Bit 7 comes straight from tx_data_i so it reflects the freshest response;
  // bits 6..0 come from the shift register.
  //
  // The select is tx_first_q, which only ever changes on a FALLING edge. Using
  // the RX bit counter here instead would be wrong: it advances on the rising
  // edge, so MISO would move at the exact moment the host samples it.
  assign miso_o = tx_first_q ? tx_data_i[DATA_W-1] : tx_shift_q[DATA_W-1];

  // ---------------------------------------------------------------------------
  // Byte-complete pulse transfer into the core clock domain.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_done_meta_q  <= 1'b0;
      rx_done_sync_q  <= 1'b0;
      rx_done_sync_qq <= 1'b0;
      rx_data_o       <= '0;
      rx_valid_o      <= 1'b0;
    end else begin
      rx_done_meta_q  <= rx_done_tgl_q;
      rx_done_sync_q  <= rx_done_meta_q;
      rx_done_sync_qq <= rx_done_sync_q;

      rx_valid_o <= 1'b0;
      if (rx_done_sync_q ^ rx_done_sync_qq) begin
        rx_data_o  <= rx_data_sclk_q;
        rx_valid_o <= 1'b1;
      end
    end
  end

endmodule
