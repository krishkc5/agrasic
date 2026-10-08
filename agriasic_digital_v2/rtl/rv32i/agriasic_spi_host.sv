// -----------------------------------------------------------------------------
// Module: agriasic_spi_host
// Purpose:
//   Host-facing SPI port for the RV32I chip (closes GAP-11). The chip is the
//   SLAVE here -- an external host drives SCK/CS_N/MOSI and reads MISO -- and
//   this block turns that byte stream into bus transactions.
//
// Why a bus master rather than a mailbox:
//   The debug module already proves the pattern: an external agent gets its own
//   master port (M2, system bus access) and reads memory while the core runs.
//   This is the same shape on M4. The host can therefore read a completed sweep
//   straight out of DMEM while the core is parked in wfi, with no firmware
//   cooperation and no handshake protocol to get wrong. A mailbox would have
//   needed firmware alive to publish results and a bespoke race-free handoff.
//
// Why these pins are NOT shared with the flash port:
//   Opposite roles mean opposite directions on every wire -- SCK/CS_N/MOSI are
//   inputs here and outputs on the flash master, MISO the reverse. Sharing them
//   would need bidirectional pads, a mode bit that can strand both paths, and a
//   host whose SPI master tri-states SCK when idle. Separate pads, per the
//   analog/package review.
//
// Permissions (enforced in agriasic_rv32i_bus, not here):
//   M4 may reach DMEM and the peripheral window ONLY. Not IMEM, so a field host
//   cannot overwrite firmware -- that stays JTAG's job. Not the debug module,
//   so a field host cannot take debug control of the core.
//
// Wire protocol (mode 0, one transaction per CS_N assertion):
//
//   byte 0      command
//                 0x03  READ   address follows, then data streams OUT
//                 0x02  WRITE  address follows, then data streams IN
//                 0x05  RDSR   status byte streams OUT immediately
//   bytes 1..4  32-bit address, BIG endian (MSB first), as SPI NOR does it
//   then        data bytes, LITTLE endian within each 32-bit word (byte 0 is
//               bits [7:0]), word address auto-incrementing by 4
//
//   Deasserting CS_N ends the transaction and resets the framing, so a host
//   that loses sync just releases CS_N and starts again.
//
//   Status byte: [0] busy (a bus access is outstanding), [1] sticky error (an
//   access was refused or the target reported an error). Reading the status
//   clears the sticky bit.
//
// Timing:
//   Max SCK is f_clk/16, inherited from spi_slave's oversampling (it is not a
//   second clock domain). One byte is therefore at least 128 core clocks, and a
//   bus access is 2, so the access always completes inside the inter-byte gap
//   and no flow control is needed on the wire.
//
// Word granularity:
//   Writes commit one whole 32-bit word at a time. A host that deasserts CS_N
//   part way through a word simply does not commit that word; nothing partial
//   is written. Byte-granular writes are deliberately not offered -- firmware
//   and the debugger both have them, and a host that needs one can
//   read-modify-write.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module agriasic_spi_host (
  input  logic        clk,
  input  logic        rst_n,

  // Host SPI pins (chip is the slave)
  input  logic        sclk_i,
  input  logic        cs_n_i,
  input  logic        mosi_i,
  output logic        miso_o,
  output logic        miso_oe_o,

  // Bus master port (M4)
  output logic        bus_req_o,
  output logic        bus_we_o,
  output logic [3:0]  bus_be_o,
  output logic [31:0] bus_addr_o,
  output logic [31:0] bus_wdata_o,
  input  logic        bus_gnt_i,
  input  logic        bus_rvalid_i,
  input  logic [31:0] bus_rdata_i,
  input  logic        bus_err_i
);

  localparam logic [7:0] CMD_READ  = 8'h03;
  localparam logic [7:0] CMD_WRITE = 8'h02;
  localparam logic [7:0] CMD_RDSR  = 8'h05;

  // ---------------------------------------------------------------------------
  // Byte-level SPI slave. Already oversamples SCK/CS_N/MOSI into clk, so there
  // is no clock-domain crossing to manage here.
  // ---------------------------------------------------------------------------
  logic [7:0] rx_data;
  logic       rx_valid;
  logic [7:0] tx_data;

  spi_slave #(.DATA_W(8)) u_spi_slave (
    .clk        (clk),
    .rst_n      (rst_n),
    .sclk_i     (sclk_i),
    .cs_n_i     (cs_n_i),
    .mosi_i     (mosi_i),
    .miso_o     (miso_o),
    .miso_oe_o  (miso_oe_o),
    .rx_data_o  (rx_data),
    .rx_valid_o (rx_valid),
    .tx_data_i  (tx_data)
  );

  // spi_slave documents miso_oe_o as tracking its own synchronized, glitch-free
  // chip-select. Reusing it as the frame-active signal avoids a second 2FF
  // synchronizer on the same pin.
  wire frame_active = miso_oe_o;
  logic frame_active_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) frame_active_q <= 1'b0;
    else        frame_active_q <= frame_active;
  end
  wire frame_end = frame_active_q && !frame_active;

  // ---------------------------------------------------------------------------
  // Framing state
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_CMD    = 3'd0,   // waiting for a command byte
    S_ADDR   = 3'd1,   // collecting 4 address bytes
    S_READ   = 3'd2,   // streaming data out
    S_WRITE  = 3'd3,   // collecting data in
    S_STATUS = 3'd4    // streaming the status byte out
  } state_e;

  state_e      state_q;
  logic [7:0]  cmd_q;
  logic [31:0] addr_q;
  logic [1:0]  addr_cnt_q;    // 0..3 address bytes seen
  logic [1:0]  byte_idx_q;    // byte within the current word
  logic [31:0] rdata_q;
  logic [31:0] wdata_q;
  logic        err_q;         // sticky

  // Bus access sub-FSM: idle -> request (until gnt) -> wait rvalid.
  typedef enum logic [1:0] { A_IDLE = 2'd0, A_REQ = 2'd1, A_WAIT = 2'd2 } acc_e;
  acc_e        acc_q;
  logic        acc_we_q;
  logic [31:0] acc_addr_q;
  logic [31:0] acc_wdata_q;
  logic        acc_start;     // pulse: begin the access described below
  logic        acc_start_we;
  logic [31:0] acc_start_addr;
  logic [31:0] acc_start_wdata;

  wire acc_busy = (acc_q != A_IDLE);

  assign bus_req_o   = (acc_q == A_REQ);
  assign bus_we_o    = acc_we_q;
  assign bus_be_o    = 4'b1111;              // whole words only, see header
  assign bus_addr_o  = acc_addr_q;
  assign bus_wdata_o = acc_wdata_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_q       <= A_IDLE;
      acc_we_q    <= 1'b0;
      acc_addr_q  <= 32'd0;
      acc_wdata_q <= 32'd0;
      rdata_q     <= 32'd0;
    end else begin
      case (acc_q)
        A_IDLE: if (acc_start) begin
          acc_q       <= A_REQ;
          acc_we_q    <= acc_start_we;
          acc_addr_q  <= acc_start_addr;
          acc_wdata_q <= acc_start_wdata;
        end
        A_REQ:  if (bus_gnt_i) acc_q <= A_WAIT;
        A_WAIT: if (bus_rvalid_i) begin
          acc_q <= A_IDLE;
          if (!bus_err_i && !acc_we_q) rdata_q <= bus_rdata_i;
        end
        default: acc_q <= A_IDLE;
      endcase
    end
  end

  // Sticky error, in its own block so the priority is explicit. It clears at
  // the END of a status transaction rather than when the RDSR command byte
  // lands -- clearing on the command would wipe the bit before the host had
  // clocked out the byte reporting it, so the host could never see an error.
  // A set always beats a simultaneous clear.
  wire acc_err_now = (acc_q == A_WAIT) && bus_rvalid_i && bus_err_i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                  err_q <= 1'b0;
    else if (acc_err_now)                        err_q <= 1'b1;
    else if (frame_end && (state_q == S_STATUS)) err_q <= 1'b0;
  end

  // ---------------------------------------------------------------------------
  // Command framing
  // ---------------------------------------------------------------------------
  always_comb begin
    acc_start       = 1'b0;
    acc_start_we    = 1'b0;
    acc_start_addr  = addr_q;
    acc_start_wdata = wdata_q;

    if (rx_valid) begin
      unique case (state_q)
        S_ADDR: if (addr_cnt_q == 2'd3 && cmd_q == CMD_READ) begin
          // Last address byte just landed: prefetch the first word now, during
          // the inter-byte gap, so it is ready before the host clocks it out.
          acc_start      = 1'b1;
          acc_start_addr = {addr_q[23:0], rx_data};
        end
        S_READ: if (byte_idx_q == 2'd3) begin
          acc_start      = 1'b1;              // last byte of the word went out
          acc_start_addr = addr_q + 32'd4;
        end
        S_WRITE: if (byte_idx_q == 2'd3) begin
          acc_start       = 1'b1;
          acc_start_we    = 1'b1;
          acc_start_wdata = {rx_data, wdata_q[23:0]};
        end
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= S_CMD;
      cmd_q      <= 8'd0;
      addr_q     <= 32'd0;
      addr_cnt_q <= 2'd0;
      byte_idx_q <= 2'd0;
      wdata_q    <= 32'd0;
    end else if (frame_end) begin
      // CS_N released: abandon whatever was in flight and resync.
      state_q    <= S_CMD;
      addr_cnt_q <= 2'd0;
      byte_idx_q <= 2'd0;
    end else if (rx_valid) begin
      unique case (state_q)
        S_CMD: begin
          cmd_q      <= rx_data;
          addr_cnt_q <= 2'd0;
          byte_idx_q <= 2'd0;
          unique case (rx_data)
            CMD_READ, CMD_WRITE: state_q <= S_ADDR;
            CMD_RDSR:            state_q <= S_STATUS;
            default:             state_q <= S_CMD;   // unknown command: ignore
          endcase
        end

        S_ADDR: begin
          addr_q <= {addr_q[23:0], rx_data};
          if (addr_cnt_q == 2'd3) begin
            byte_idx_q <= 2'd0;
            state_q    <= (cmd_q == CMD_READ) ? S_READ : S_WRITE;
          end else begin
            addr_cnt_q <= addr_cnt_q + 2'd1;
          end
        end

        S_READ: begin
          byte_idx_q <= byte_idx_q + 2'd1;      // wraps 3 -> 0
          if (byte_idx_q == 2'd3) addr_q <= addr_q + 32'd4;
        end

        S_WRITE: begin
          // Little endian within the word: byte 0 lands in [7:0].
          unique case (byte_idx_q)
            2'd0: wdata_q[7:0]   <= rx_data;
            2'd1: wdata_q[15:8]  <= rx_data;
            2'd2: wdata_q[23:16] <= rx_data;
            2'd3: wdata_q[31:24] <= rx_data;
          endcase
          byte_idx_q <= byte_idx_q + 2'd1;
          if (byte_idx_q == 2'd3) addr_q <= addr_q + 32'd4;
        end

        S_STATUS: ;                              // keep returning status

        default: state_q <= S_CMD;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Transmit byte. Driven combinationally from registers that are stable
  // through the whole inter-byte gap, which is what spi_slave's TX path needs.
  // ---------------------------------------------------------------------------
  always_comb begin
    unique case (state_q)
      S_STATUS: tx_data = {6'd0, err_q, acc_busy};
      S_READ:   unique case (byte_idx_q)
                  2'd0: tx_data = rdata_q[7:0];
                  2'd1: tx_data = rdata_q[15:8];
                  2'd2: tx_data = rdata_q[23:16];
                  2'd3: tx_data = rdata_q[31:24];
                endcase
      default:  tx_data = 8'h00;
    endcase
  end

`ifndef SYNTHESIS
  // A byte is at least 128 core clocks (SCK <= f_clk/16) and an access is two,
  // so an access must never still be running when the next byte arrives. If
  // this fires, either the SCK limit was violated or the bus stalled.
  always_ff @(posedge clk) begin
    if (rst_n && rx_valid && (state_q == S_READ)) begin
      assert (!acc_busy)
        else $error("agriasic_spi_host: bus access still busy at a byte boundary");
    end
  end
`endif

endmodule
