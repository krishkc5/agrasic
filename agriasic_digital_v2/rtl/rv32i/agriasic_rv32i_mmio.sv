// -----------------------------------------------------------------------------
// Module: agriasic_rv32i_mmio
// Purpose:
//   Data-side bus for the Ibex control core. Decodes the core's OBI-style data
//   port into scratch RAM and a memory-mapped peripheral window that drives
//   the measurement engine.
//
//   Ibex replaces the Penn CIS 5710 core (previous bridge preserved as
//   agriasic_rv32i_mmio.sv.penn). Two things changed at this boundary:
//     1. The port is the Ibex/OBI request-grant-rvalid handshake instead of a
//        raw SRAM strobe. Grant is combinational (always ready), rvalid is the
//        registered request: the same 1-cycle contract the SRAM wrapper and
//        the previous bridge already implemented.
//     2. The decode is now FULL. Previously only addr[31] and addr[4:2] were
//        looked at, so any address outside the two windows silently aliased.
//        Now anything outside RAM or the peripheral window returns data_err,
//        which Ibex turns into a load/store access-fault trap. An out-of-map
//        store is a visible fault in silicon, not a silent write to nowhere.
//
// Memory map (data side; Phase 2 flat map, see agriasic_rv32i_bus.sv):
//   RAM_BASE .. RAM_BASE+RAM_BYTES-1 : scratch RAM (stack / working data),
//                                      RAM_BASE = 0x0001_0000 in the shell
//   0x8000_0000 - 0x8000_001F        : peripheral window
//   everything else                  : bus error (data_err_o)
//
//   The bridge sits behind agriasic_rv32i_bus, which arbitrates the core's
//   data port and the debug module's system-bus master onto this one port.
//
// Peripheral registers (word aligned, selected by addr[4:2]):
//   0x8000_0000  CTRL       W   bit0 = start
//                                bit7 = clear sticky errors
//                                bit8 = FW_DONE   (sticky; firmware finished,
//                                                  replaces the old ecall halt)
//                                bit9 = TRAP_SEEN (sticky; written by the trap
//                                                  handler so a fault is visible)
//   0x8000_0004  PAIR_LOG2  RW  [3:0]
//   0x8000_0008  SETTLE     RW  [7:0]
//   0x8000_000C  DIVIDER    RW  [13:0] raw N (see the Rev 4.3 Phase 4.2/6 note
//                                       in the MAS on why MMIO and SPI differ)
//   0x8000_0010  CONV       RW  [7:0]
//   0x8000_0014  STATUS     R   bit0 = busy, bit1 = done, bit4 = overrange,
//                                bit5 = trap_seen, bit6 = fw_done
//   0x8000_0018  RESULT_I   R   [15:0] signed I-channel accumulator
//   0x8000_001C  RESULT_Q   R   [15:0] signed Q-channel accumulator
//
// Sleep / wake:
//   meas_done_irq_o is the sticky DONE latch, exported so the shell can feed
//   it to Ibex's irq_fast_i[0]. Firmware writes START, executes wfi, and
//   Ibex wakes when DONE goes pending (mie.fast0 set, mstatus.MIE clear, so
//   no trap is taken -- execution simply resumes after the wfi). The next
//   START clears the latch. This replaces the previous shell's core_clk_en.
//
// Timing contract:
//   Peripheral reads are registered so the window presents the SAME 1-cycle
//   read latency as the SRAM macro; rvalid is asserted one cycle after req
//   for both slaves and for errors.
//
// Pulse generation:
//   A store to CTRL asserts data_we for exactly one cycle (OBI: one request
//   per transfer), so a registered decode of that write yields the
//   single-cycle start pulse the measurement FSM requires.
// -----------------------------------------------------------------------------
module agriasic_rv32i_mmio #(
  parameter int unsigned RAM_WORDS = 1024,
  parameter logic [31:0] RAM_BASE  = 32'h0001_0000
) (
  input  logic        clk,
  input  logic        rst_n,
  // Clears the firmware-owned sticky bits (FW_DONE, TRAP_SEEN) whenever the
  // core is put back into reset by the shell, so a new run starts clean.
  input  logic        run_clear_i,

  // Data-side port from Ibex (OBI-style).
  input  logic        data_req_i,
  output logic        data_gnt_o,
  output logic        data_rvalid_o,
  input  logic        data_we_i,
  input  logic [3:0]  data_be_i,
  input  logic [31:0] data_addr_i,   // word aligned by the Ibex LSU
  input  logic [31:0] data_wdata_i,
  output logic [31:0] data_rdata_o,
  output logic        data_err_o,

  // Control outputs to the measurement engine.
  output logic        start_pulse_o,
  output logic        clear_errors_o,
  output logic [3:0]  cfg_pair_log2_o,
  output logic [7:0]  cfg_settle_cycles_o,
  output logic [13:0] cfg_exc_divider_o,
  output logic [7:0]  cfg_conv_cycles_o,

  // Firmware-state outputs to the shell.
  output logic        fw_done_o,        // firmware wrote CTRL.FW_DONE
  output logic        trap_seen_o,      // firmware wrote CTRL.TRAP_SEEN
  output logic        meas_done_irq_o,  // sticky DONE latch, level interrupt

  // Status inputs from the measurement engine.
  //   done_i is the FSM's RAW single-cycle done pulse.
  input  logic        done_i,
  input  logic signed [15:0] result_i_i,
  input  logic signed [15:0] result_q_i
);

  localparam int unsigned RAM_BYTES  = RAM_WORDS * 4;

  localparam logic [2:0] REG_CTRL      = 3'd0;
  localparam logic [2:0] REG_PAIR_LOG2 = 3'd1;
  localparam logic [2:0] REG_SETTLE    = 3'd2;
  localparam logic [2:0] REG_DIVIDER   = 3'd3;
  localparam logic [2:0] REG_CONV      = 3'd4;
  localparam logic [2:0] REG_STATUS    = 3'd5;
  localparam logic [2:0] REG_RESULT_I  = 3'd6;
  localparam logic [2:0] REG_RESULT_Q  = 3'd7;

  localparam logic [31:0] PERIPH_BASE  = 32'h8000_0000;
  localparam logic [31:0] PERIPH_MASK  = 32'hFFFF_FFE0;   // 32-byte window

  // --------------------------------------------------------------------------
  // Address decode (full)
  // --------------------------------------------------------------------------
  wire        ram_sel    = (data_addr_i >= RAM_BASE) && (data_addr_i < RAM_BASE + RAM_BYTES);
  // agriasic_dmem indexes by the low address bits, so it sees the offset
  // within the RAM window regardless of where the window is based.
  wire [31:0] ram_addr   = data_addr_i - RAM_BASE;
  wire        periph_sel = ((data_addr_i & PERIPH_MASK) == PERIPH_BASE);
  wire        unmapped   = !ram_sel && !periph_sel;
  wire [2:0]  periph_reg = data_addr_i[4:2];

  wire        periph_wr  = data_req_i && periph_sel &&  data_we_i && data_be_i[0];
  wire        periph_rd  = data_req_i && periph_sel && !data_we_i;
  wire        ram_ce     = data_req_i && ram_sel;
  wire [3:0]  ram_we     = data_we_i ? data_be_i : 4'b0000;

  // Always ready: both slaves complete every transfer in exactly one cycle.
  assign data_gnt_o = data_req_i;

  // --------------------------------------------------------------------------
  // Scratch RAM
  // --------------------------------------------------------------------------
  logic [31:0] ram_dout;

  agriasic_dmem #(
    .NUM_WORDS(RAM_WORDS)
  ) u_dmem (
    .clk    (clk),
    .rst_n  (rst_n),
    .ce_i   (ram_ce),
    .we_i   (ram_we),
    .addr_i (ram_addr),
    .din_i  (data_wdata_i),
    .dout_o (ram_dout)
  );

  // --------------------------------------------------------------------------
  // Configuration registers
  //
  // Reset values match the defaults the original control shell applied, so
  // the measurement engine behaves identically out of reset with no firmware.
  // --------------------------------------------------------------------------
  logic [3:0]  cfg_pair_log2_q;
  logic [7:0]  cfg_settle_q;
  logic [13:0] cfg_divider_q;
  logic [7:0]  cfg_conv_q;
  logic        fw_done_q;
  logic        trap_seen_q;

  assign cfg_pair_log2_o     = cfg_pair_log2_q;
  assign cfg_settle_cycles_o = cfg_settle_q;
  assign cfg_exc_divider_o   = cfg_divider_q;
  assign cfg_conv_cycles_o   = cfg_conv_q;
  assign fw_done_o           = fw_done_q;
  assign trap_seen_o         = trap_seen_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_pair_log2_q <= 4'd2;
      cfg_settle_q    <= 8'd2;
      cfg_divider_q   <= 14'd0;
      cfg_conv_q      <= 8'd1;
      start_pulse_o   <= 1'b0;
      clear_errors_o  <= 1'b0;
      fw_done_q       <= 1'b0;
      trap_seen_q     <= 1'b0;
    end else begin
      // Default low: both are single-cycle pulses.
      start_pulse_o  <= 1'b0;
      clear_errors_o <= 1'b0;

      if (run_clear_i) begin
        fw_done_q   <= 1'b0;
        trap_seen_q <= 1'b0;
      end

      if (periph_wr) begin
        unique case (periph_reg)
          REG_CTRL: begin
            start_pulse_o  <= data_wdata_i[0];
            clear_errors_o <= data_wdata_i[7];
            if (data_be_i[1]) begin
              if (data_wdata_i[8]) fw_done_q   <= 1'b1;
              if (data_wdata_i[9]) trap_seen_q <= 1'b1;
            end
          end
          REG_PAIR_LOG2: cfg_pair_log2_q <= data_wdata_i[3:0];
          REG_SETTLE:    cfg_settle_q    <= data_wdata_i[7:0];
          REG_DIVIDER:   cfg_divider_q   <= data_wdata_i[13:0];
          REG_CONV:      cfg_conv_q      <= data_wdata_i[7:0];
          // STATUS and RESULT are read-only; writes are ignored.
          default: begin
          end
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------
  // Measurement status latches
  //
  // busy MUST set in the same cycle the CTRL start write is registered: the
  // firmware fallback path (poll STATUS after START) reads it the very next
  // cycle. done is latched sticky because the FSM's done_o is a single-cycle
  // pulse, and it doubles as the level-sensitive wake interrupt for wfi.
  // --------------------------------------------------------------------------
  wire ctrl_start_write = periph_wr && (periph_reg == REG_CTRL) && data_wdata_i[0];

  logic meas_busy_q;
  logic meas_done_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      meas_busy_q <= 1'b0;
      meas_done_q <= 1'b0;
    end else if (ctrl_start_write) begin
      meas_busy_q <= 1'b1;
      meas_done_q <= 1'b0;
    end else if (done_i) begin
      meas_busy_q <= 1'b0;
      meas_done_q <= 1'b1;
    end
  end

  assign meas_done_irq_o = meas_done_q;

  // --------------------------------------------------------------------------
  // Peripheral read path (registered: same 1-cycle latency as the SRAM)
  // --------------------------------------------------------------------------
  wire status_overrange_w = (cfg_pair_log2_q > 4'd6);

  logic [31:0] periph_rdata;
  always_comb begin
    unique case (periph_reg)
      REG_PAIR_LOG2: periph_rdata = {28'd0, cfg_pair_log2_q};
      REG_SETTLE:    periph_rdata = {24'd0, cfg_settle_q};
      REG_DIVIDER:   periph_rdata = {18'd0, cfg_divider_q};
      REG_CONV:      periph_rdata = {24'd0, cfg_conv_q};
      REG_STATUS:    periph_rdata = {25'd0, fw_done_q, trap_seen_q, status_overrange_w,
                                     2'b00, meas_done_q, meas_busy_q};
      REG_RESULT_I:  periph_rdata = {{16{result_i_i[15]}}, result_i_i};
      REG_RESULT_Q:  periph_rdata = {{16{result_q_i[15]}}, result_q_i};
      default:       periph_rdata = 32'd0;
    endcase
  end

  // --------------------------------------------------------------------------
  // Response: rvalid/err one cycle after every request, data muxed by the
  // registered decode so it lines up with the 1-cycle return.
  // --------------------------------------------------------------------------
  logic        rvalid_q;
  logic        err_q;
  logic        periph_rd_q;
  logic [31:0] periph_dout_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rvalid_q      <= 1'b0;
      err_q         <= 1'b0;
      periph_rd_q   <= 1'b0;
      periph_dout_q <= 32'd0;
    end else begin
      rvalid_q    <= data_req_i;
      err_q       <= data_req_i && unmapped;
      periph_rd_q <= periph_rd;
      if (periph_rd) begin
        periph_dout_q <= periph_rdata;
      end
    end
  end

  assign data_rvalid_o = rvalid_q;
  assign data_err_o    = err_q;
  assign data_rdata_o  = periph_rd_q ? periph_dout_q : ram_dout;

endmodule
