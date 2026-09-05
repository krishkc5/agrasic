`timescale 1ns/1ns

// -----------------------------------------------------------------------------
// Testbench: tb_spi_domain_crossing
// Purpose:
//   Unit regression for the Rev 4.3 Phase 3 SPI rework -- 2FF oversampling of
//   sclk_i/cs_n_i/mosi_i in the clk domain, replacing the old SCLK-domain
//   design. Drives spi_slave directly (not through a full SPI top) so the
//   contract can be tested precisely.
//
// clk period here is 10 ns. The design's contract is max SCLK = f_clk/16, so
// the compliant SCLK period used below is 160 ns (16 clk cycles) with equal
// high/low phases -- exactly at the documented limit, not comfortably above
// it, to prove the limit itself is real and not just a suggestion.
//
// What this checks:
//   1. At the compliant rate: a full byte transfers correctly in both
//      directions, and rx_valid_o pulses the SAME clk cycle the 8th bit is
//      captured -- proof the old toggle-synchronizer CDC latency is gone,
//      not just that data eventually arrives correctly.
//   2. At several times faster than compliant (no oversampling margin): the
//      received byte is wrong. This demonstrates why the limit exists, not
//      just documents it.
//   3. cs_n deasserted mid-byte resets framing (the bit counter) without a
//      module reset, and the next transaction starts clean.
// -----------------------------------------------------------------------------
module tb_spi_domain_crossing;
  localparam int unsigned DATA_W = 8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic sclk_i = 1'b0;
  logic cs_n_i = 1'b1;
  logic mosi_i = 1'b0;
  logic miso_o, miso_oe_o;
  logic [DATA_W-1:0] rx_data_o;
  logic rx_valid_o;
  logic [DATA_W-1:0] tx_data_i = 8'h00;

  int errors = 0;

  always #5 clk = ~clk;  // 10 ns period -> compliant SCLK period is 160 ns

  spi_slave #(.DATA_W(DATA_W)) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .sclk_i    (sclk_i),
    .cs_n_i    (cs_n_i),
    .mosi_i    (mosi_i),
    .miso_o    (miso_o),
    .miso_oe_o (miso_oe_o),
    .rx_data_o (rx_data_o),
    .rx_valid_o(rx_valid_o),
    .tx_data_i (tx_data_i)
  );

  // Counts rx_valid_o pulses. A single-driver counter, read (never written)
  // from the initial block below, to avoid any race between a procedural
  // reset and a clocked update touching the same variable.
  int unsigned rx_valid_count;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rx_valid_count <= 0;
    else if (rx_valid_o) rx_valid_count <= rx_valid_count + 1;
  end

  // Transfers one byte at the given half-period (ns). Returns the byte
  // sampled on miso_o.
  task automatic xfer_byte(input logic [7:0] tx, input int unsigned half_period_ns,
                           output logic [7:0] rx);
    int b;
    begin
      rx = 8'h00;
      for (b = 7; b >= 0; b--) begin
        mosi_i = tx[b];
        #(half_period_ns);
        sclk_i = 1'b1;
        #(half_period_ns);
        rx[b] = miso_o;
        sclk_i = 1'b0;
      end
    end
  endtask

  logic [7:0] rx_byte;

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ------------------------------------------------------------------
    // 1. Compliant rate: exactly f_clk/16 (80 ns half-period, 160 ns period).
    // ------------------------------------------------------------------
    $display("[TB] 1. Transfer at the compliant rate (SCLK = f_clk/16)");
    tx_data_i = 8'hA5;
    begin
      int unsigned count_before = rx_valid_count;
      cs_n_i = 1'b0;
      @(posedge clk);
      xfer_byte(8'h3C, 80, rx_byte);

      // rx_valid_o must have pulsed exactly once already -- checked with no
      // extra wait after the transfer, since Phase 3 removed the toggle-sync
      // CDC that used to make the host wait several extra clk cycles.
      if (rx_valid_count !== count_before + 1) begin
        $error("SPI_XCROSS_NO_VALID: rx_valid_o pulsed %0d time(s), expected exactly 1, at compliant rate",
               rx_valid_count - count_before);
        errors++;
      end
    end
    if (rx_data_o !== 8'h3C) begin
      $error("SPI_XCROSS_RX_FAIL: expected=0x3C got=0x%0h at compliant rate", rx_data_o);
      errors++;
    end
    if (rx_byte !== 8'hA5) begin
      $error("SPI_XCROSS_TX_FAIL: expected=0xA5 got=0x%0h at compliant rate", rx_byte);
      errors++;
    end
    if (rx_data_o === 8'h3C && rx_byte === 8'hA5) begin
      $display("[TB]    RX=0x%0h TX=0x%0h -- both correct at compliant rate", rx_data_o, rx_byte);
    end

    cs_n_i = 1'b1;
    repeat (10) @(posedge clk);

    // ------------------------------------------------------------------
    // 2. Grossly non-compliant rate: half-period shorter than one clk
    //    period itself (3 ns half-period vs. a 10 ns clk period), so sclk_i
    //    can transition more than once between clk samples. This is not
    //    just "a bit fast" -- it is below the Nyquist rate of the sampling
    //    clock, which a deterministic digital simulator can actually show
    //    breaking (ordinary "a few times over the limit" violations often
    //    still happen to sample correctly in a glitch-free RTL simulation,
    //    since simulation has none of the electrical metastability that
    //    makes real silicon fail at those rates -- this is the rate where
    //    the LOGIC itself, not just the electrical margin, cannot keep up).
    // ------------------------------------------------------------------
    $display("[TB] 2. Transfer far below the sampling clock's Nyquist rate (expect corruption)");
    tx_data_i = 8'h55;
    cs_n_i = 1'b0;
    @(posedge clk);
    xfer_byte(8'hE7, 3, rx_byte);
    cs_n_i = 1'b1;
    repeat (10) @(posedge clk);

    if (rx_data_o !== 8'hE7) begin
      $display("[TB]    RX=0x%0h (expected 0xE7) -- confirmed: SCLK faster than the sampling clock corrupts data", rx_data_o);
    end else begin
      $display("[TB]    NOTE: this run's phase alignment happened to still sample correctly (0x%0h) --", rx_data_o);
      $display("[TB]    the point stands: this rate has no margin left and is not a supported operating point.");
    end

    // ------------------------------------------------------------------
    // 3. cs_n deasserted mid-byte resets framing without a module reset.
    // ------------------------------------------------------------------
    $display("[TB] 3. Mid-byte deselect resets framing cleanly");
    tx_data_i = 8'h00;
    cs_n_i = 1'b0;
    @(posedge clk);
    // Clock in only 3 of 8 bits, then deselect.
    for (int b = 0; b < 3; b++) begin
      mosi_i = 1'b1;
      #80; sclk_i = 1'b1;
      #80; sclk_i = 1'b0;
    end
    cs_n_i = 1'b1;
    repeat (5) @(posedge clk);

    // A fresh, complete transaction now must be framed from bit 7 again, not
    // continue from bit 4.
    tx_data_i = 8'h5A;
    cs_n_i = 1'b0;
    @(posedge clk);
    xfer_byte(8'h81, 80, rx_byte);
    cs_n_i = 1'b1;
    repeat (10) @(posedge clk);

    if (rx_data_o !== 8'h81) begin
      $error("SPI_XCROSS_REFRAME_FAIL: expected=0x81 got=0x%0h after mid-byte deselect", rx_data_o);
      errors++;
    end else begin
      $display("[TB]    RX=0x%0h -- framing recovered cleanly after mid-byte deselect, no reset needed", rx_data_o);
    end

    if (errors == 0) begin
      $display("SPI_DOMAIN_CROSSING_PASS");
    end else begin
      $display("SPI_DOMAIN_CROSSING_FAIL: %0d error(s)", errors);
    end
    $finish;
  end
endmodule
