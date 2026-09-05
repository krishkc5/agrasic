// -----------------------------------------------------------------------------
// Module: agriasic_rv32i_mmio
// Purpose:
//   Data-side bus for the RV32I control core. Decodes the core's dmem port
//   into scratch RAM and a memory-mapped peripheral window that drives the
//   measurement engine.
//
// Memory map (data side):
//   0x0000_0000 - RAM_BYTES-1 : scratch RAM (stack / working data)
//   0x8000_0000 - 0x8000_001F : peripheral window (addr_i[31] == 1)
//
// Peripheral registers (word aligned, selected by addr_i[4:2]):
//   0x8000_0000  CTRL       W   bit0 = start, bit7 = clear sticky errors
//   0x8000_0004  PAIR_LOG2  RW  [3:0]
//   0x8000_0008  SETTLE     RW  [7:0]
//   0x8000_000C  DIVIDER    RW  [13:0] (Rev 4.3 Phase 4.2: widened from [7:0],
//                                       see GAP-1. Native 32-bit MMIO writes
//                                       have no byte-framing constraint, so
//                                       firmware can reach the full 14-bit
//                                       range today -- unlike the SPI/prog
//                                       host paths, which stay 8-bit-windowed
//                                       until Phase 6 formalizes the encoding)
//   0x8000_0010  CONV       RW  [7:0]
//   0x8000_0014  STATUS     R   bit0 = busy, bit1 = done
//   0x8000_0018  RESULT     R   [15:0] signed accumulator
//
// Timing contract:
//   Peripheral reads are registered so the window presents the SAME 1-cycle
//   read latency as the SRAM macro. Without this, loads from the peripheral
//   window would return data one cycle early and desynchronize Writeback.
//
// Pulse generation:
//   A store to CTRL asserts we_i for exactly one cycle, so a registered decode
//   of that write yields the single-cycle start pulse the measurement FSM
//   requires. No edge detection or pulse stretching is needed.
// -----------------------------------------------------------------------------
module agriasic_rv32i_mmio #(
  parameter int unsigned RAM_WORDS = 1024
) (
  input  logic        clk,
  input  logic        rst_n,

  // Data-side port from the RV32I core.
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  input  logic [3:0]  we_i,
  input  logic        read_en_i,
  output logic [31:0] rdata_o,

  // Control outputs to the measurement engine.
  output logic        start_pulse_o,
  output logic        clear_errors_o,
  output logic [3:0]  cfg_pair_log2_o,
  output logic [7:0]  cfg_settle_cycles_o,
  output logic [13:0] cfg_exc_divider_o,
  output logic [7:0]  cfg_conv_cycles_o,

  // Status inputs from the measurement engine.
  //   done_i is the FSM's RAW single-cycle done pulse.
  input  logic        done_i,
  input  logic [15:0] result_i
);

  localparam logic [2:0] REG_CTRL      = 3'd0;
  localparam logic [2:0] REG_PAIR_LOG2 = 3'd1;
  localparam logic [2:0] REG_SETTLE    = 3'd2;
  localparam logic [2:0] REG_DIVIDER   = 3'd3;
  localparam logic [2:0] REG_CONV      = 3'd4;
  localparam logic [2:0] REG_STATUS    = 3'd5;
  localparam logic [2:0] REG_RESULT    = 3'd6;

  // --------------------------------------------------------------------------
  // Address decode
  // --------------------------------------------------------------------------
  wire        periph_sel = addr_i[31];
  wire [2:0]  periph_reg = addr_i[4:2];
  wire        is_write   = |we_i;
  wire        is_read    = read_en_i;
  wire        access     = is_read || is_write;

  wire        periph_wr  = periph_sel && is_write && we_i[0];
  wire        periph_rd  = periph_sel && is_read;
  wire        ram_ce     = access && !periph_sel;

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
    .we_i   (we_i),
    .addr_i (addr_i),
    .din_i  (wdata_i),
    .dout_o (ram_dout)
  );

  // --------------------------------------------------------------------------
  // Configuration registers
  //
  // Reset values match the defaults the previous control shell applied, so the
  // measurement engine behaves identically out of reset with no firmware.
  // --------------------------------------------------------------------------
  logic [3:0] cfg_pair_log2_q;
  logic [7:0] cfg_settle_q;
  logic [13:0] cfg_divider_q;
  logic [7:0] cfg_conv_q;

  assign cfg_pair_log2_o     = cfg_pair_log2_q;
  assign cfg_settle_cycles_o = cfg_settle_q;
  assign cfg_exc_divider_o   = cfg_divider_q;
  assign cfg_conv_cycles_o   = cfg_conv_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_pair_log2_q <= 4'd2;
      cfg_settle_q    <= 8'd2;
      cfg_divider_q   <= 14'd0;
      cfg_conv_q      <= 8'd1;
      start_pulse_o   <= 1'b0;
      clear_errors_o  <= 1'b0;
    end else begin
      // Default low: both are single-cycle pulses.
      start_pulse_o  <= 1'b0;
      clear_errors_o <= 1'b0;

      if (periph_wr) begin
        unique case (periph_reg)
          REG_CTRL: begin
            start_pulse_o  <= wdata_i[0];
            clear_errors_o <= wdata_i[7];
          end
          REG_PAIR_LOG2: cfg_pair_log2_q <= wdata_i[3:0];
          REG_SETTLE:    cfg_settle_q    <= wdata_i[7:0];
          REG_DIVIDER:   cfg_divider_q   <= wdata_i[13:0];
          REG_CONV:      cfg_conv_q      <= wdata_i[7:0];
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
  // These MUST update in the same cycle the CTRL start write is registered.
  // Firmware's typical sequence is
  //     sw  start -> CTRL
  //     lw  STATUS
  // on back-to-back cycles. If busy lagged the write by even one cycle, that
  // load would read busy == 0, firmware would conclude the measurement had
  // already completed, and it would consume a stale RESULT.
  //
  // done is latched sticky for the opposite reason: the FSM's done_o is a
  // single-cycle pulse (its start is a pulse, so it leaves DONE immediately),
  // which polling firmware would never observe.
  // --------------------------------------------------------------------------
  wire ctrl_start_write = periph_wr && (periph_reg == REG_CTRL) && wdata_i[0];

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

  // --------------------------------------------------------------------------
  // Peripheral read path
  //
  // Registered to match the SRAM macro's 1-cycle read latency.
  // --------------------------------------------------------------------------
  logic [31:0] periph_rdata;
  logic        periph_rd_q;

  always_comb begin
    unique case (periph_reg)
      REG_PAIR_LOG2: periph_rdata = {28'd0, cfg_pair_log2_q};
      REG_SETTLE:    periph_rdata = {24'd0, cfg_settle_q};
      REG_DIVIDER:   periph_rdata = {18'd0, cfg_divider_q};
      REG_CONV:      periph_rdata = {24'd0, cfg_conv_q};
      REG_STATUS:    periph_rdata = {30'd0, meas_done_q, meas_busy_q};
      REG_RESULT:    periph_rdata = {{16{result_i[15]}}, result_i};
      default:       periph_rdata = 32'd0;
    endcase
  end

  logic [31:0] periph_dout_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      periph_dout_q <= 32'd0;
      periph_rd_q   <= 1'b0;
    end else begin
      periph_rd_q <= periph_rd;
      if (periph_rd) begin
        periph_dout_q <= periph_rdata;
      end
    end
  end

  // Select which slave answers this cycle, using the registered decode so the
  // mux lines up with the 1-cycle data return.
  assign rdata_o = periph_rd_q ? periph_dout_q : ram_dout;

endmodule
