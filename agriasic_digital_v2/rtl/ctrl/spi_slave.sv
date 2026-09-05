// -----------------------------------------------------------------------------
// Module: spi_slave
// Purpose:
//   SPI mode-0 byte-serial slave (CPOL=0, CPHA=0) for control-plane exchange.
//
// Rev 4.3 Phase 3 -- SPI moved fully into the clk domain:
//   The earlier version ran RX on posedge sclk_i and TX on negedge sclk_i,
//   its own small clock domain, and crossed rx_valid_o back into clk via a
//   toggle synchronizer. That is gone. sclk_i, cs_n_i and mosi_i are now
//   oversampled with 2FF synchronizers in the clk domain; every bit/byte
//   event is detected as an edge on the SYNCHRONIZED signal, and every
//   register in this module -- RX shift, TX shift, bit counter -- lives on
//   posedge clk. SPI is still the only asynchronous boundary in the design
//   (MAS section 8.1/9.2), but it is now a boundary this module synchronizes
//   itself, rather than a second clock domain living inside it.
//
//   This also removes the toggle-synchronizer CDC for rx_valid_o entirely:
//   byte completion is detected directly in the clk domain (it's where RX
//   already lives), so there is nothing left to cross. rx_valid_o pulses the
//   same clk cycle the 8th bit is captured.
//
// Timing contract host firmware must respect:
//   Max SCLK = f_clk / 16. The 2FF synchronizers need several stable clk
//   cycles on each side of an edge to detect it reliably; f_clk/16 gives each
//   SCLK half-period 8 clk cycles of margin. This is what "enforce" means
//   here in practice: the design is only correct at or below this rate, by
//   construction of the oversampling ratio, not by any runtime rate check.
//   tb_spi_domain_crossing.sv verifies correct operation at exactly this rate
//   and shows how a several-times-faster host clock corrupts the byte.
//
// cs_n and framing (Rev 4.3 contract, section 7 of the baseline doc):
//   A synchronized cs_n_i rising edge resets ONLY this module's own framing
//   state (the bit counter, the TX shift register, tx_first_q) -- never
//   measurement state, which this module has no access to in the first
//   place. Mid-byte deselection is therefore always safe: the next select
//   starts a clean new byte.
//
// TX timing (still the subtle part, now entirely inside the clk domain):
//   The first bit of each byte is driven combinationally from tx_data_i,
//   which has had the whole inter-byte gap to settle; only the remaining
//   seven bits come from the shift register, loaded on the first detected
//   falling edge of the byte. This preserves the pre-Phase-3 behavior:
//   without it, a response byte decoded during the inter-byte gap could be
//   loaded a cycle too late and the host would read the PREVIOUS response.
//
// Host requirement:
//   Leave an inter-byte gap of at least a few core clocks so a freshly
//   decoded response is stable before the next byte's first falling edge.
//   The command/data byte gap used by the register protocol is ample.
//
// MISO output enable:
//   miso_oe_o tracks cs_n_sync_q combinationally -- itself already a clean,
//   synchronized, glitch-free signal, so no extra registration is needed.
//   High only while selected; pad-level logic uses it to put MISO in high-Z
//   otherwise.
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
  output logic              miso_oe_o,
  output logic [DATA_W-1:0] rx_data_o,
  output logic              rx_valid_o,
  input  logic [DATA_W-1:0] tx_data_i
);

  // ---------------------------------------------------------------------------
  // 2FF oversampling synchronizers. cs_n_i idles high (deselected), so its
  // chain resets to 1; sclk_i and mosi_i idle low.
  // ---------------------------------------------------------------------------
  logic sclk_meta_q, sclk_sync_q, sclk_sync_qq;
  logic cs_n_meta_q, cs_n_sync_q, cs_n_sync_qq;
  logic mosi_meta_q, mosi_sync_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_meta_q  <= 1'b0;
      sclk_sync_q  <= 1'b0;
      sclk_sync_qq <= 1'b0;
      cs_n_meta_q  <= 1'b1;
      cs_n_sync_q  <= 1'b1;
      cs_n_sync_qq <= 1'b1;
      mosi_meta_q  <= 1'b0;
      mosi_sync_q  <= 1'b0;
    end else begin
      sclk_meta_q  <= sclk_i;
      sclk_sync_q  <= sclk_meta_q;
      sclk_sync_qq <= sclk_sync_q;
      cs_n_meta_q  <= cs_n_i;
      cs_n_sync_q  <= cs_n_meta_q;
      cs_n_sync_qq <= cs_n_sync_q;
      mosi_meta_q  <= mosi_i;
      mosi_sync_q  <= mosi_meta_q;
    end
  end

  // Edge detection on the synchronized signals -- this is where SCLK's
  // rising/falling edges and cs_n's deselect edge are actually observed now.
  wire sclk_rise   = sclk_sync_q & ~sclk_sync_qq;
  wire sclk_fall   = ~sclk_sync_q & sclk_sync_qq;
  wire cs_n_rise   = cs_n_sync_q & ~cs_n_sync_qq;
  wire cs_n_active = ~cs_n_sync_q;

  // ---------------------------------------------------------------------------
  // RX: capture MOSI on a detected SCLK rising edge (mode 0). Byte completion
  // is native to this domain now -- rx_valid_o needs no CDC.
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] rx_shift_q;
  logic [2:0]        bit_cnt_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_shift_q <= '0;
      bit_cnt_q  <= 3'd0;
      rx_data_o  <= '0;
      rx_valid_o <= 1'b0;
    end else begin
      rx_valid_o <= 1'b0;

      if (cs_n_rise) begin
        // Deselected: reset framing only, never any state outside this
        // module (which has none of the measurement state to touch anyway).
        bit_cnt_q <= 3'd0;
      end else if (cs_n_active && sclk_rise) begin
        rx_shift_q <= {rx_shift_q[DATA_W-2:0], mosi_sync_q};

        if (bit_cnt_q == 3'd7) begin
          bit_cnt_q  <= 3'd0;
          rx_data_o  <= {rx_shift_q[DATA_W-2:0], mosi_sync_q};
          rx_valid_o <= 1'b1;
        end else begin
          bit_cnt_q <= bit_cnt_q + 3'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // TX: change MISO on a detected SCLK falling edge (mode 0).
  //
  // tx_first_q marks "the next bit out is bit 7 of a fresh byte". It is set
  // when bit_cnt_q reads 0 at a falling edge (the byte just closed) and
  // cleared on the first falling edge of the next byte, where the remaining
  // seven bits are latched from tx_data_i. bit_cnt_q is written by the RX
  // block above on sclk_rise; by the time the corresponding sclk_fall is
  // detected here (roughly half an SCLK period later -- many clk cycles,
  // given the 16x-plus oversampling ratio), that write has long since
  // settled, so there is no race between the two blocks.
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] tx_shift_q;
  logic              tx_first_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift_q <= '0;
      tx_first_q <= 1'b1;
    end else if (cs_n_rise) begin
      tx_shift_q <= '0;
      tx_first_q <= 1'b1;
    end else if (cs_n_active && sclk_fall) begin
      if (bit_cnt_q == 3'd0) begin
        // Falling edge that closes a byte: the next byte starts from
        // tx_data_i again, which by then carries the freshly decoded
        // response.
        tx_first_q <= 1'b1;
      end else if (tx_first_q) begin
        // First falling edge of a byte: latch the remaining seven bits.
        tx_shift_q <= {tx_data_i[DATA_W-2:0], 1'b0};
        tx_first_q <= 1'b0;
      end else begin
        tx_shift_q <= {tx_shift_q[DATA_W-2:0], 1'b0};
      end
    end
  end

  // Bit 7 comes straight from tx_data_i so it reflects the freshest response;
  // bits 6..0 come from the shift register. The select is tx_first_q, which
  // only ever changes on a detected falling edge -- using the RX bit counter
  // here instead would be wrong: it advances on the rising edge, so MISO
  // would move at the exact moment the host samples it.
  assign miso_o    = tx_first_q ? tx_data_i[DATA_W-1] : tx_shift_q[DATA_W-1];
  assign miso_oe_o = cs_n_active;

endmodule
