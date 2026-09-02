// -----------------------------------------------------------------------------
// Module: agriasic_digital_programming_top
// Purpose:
//   Programming-oriented wrapper for the optional RV32I controller
//   architecture. This wrapper keeps the measurement FSM as the real-time
//   engine and exposes a compact programming surface for firmware-driven setup.
//
// Notes:
//   - This is a control/programming layer, not the timing-critical measurement
//     engine itself.
//   - The wrapper keeps the same measurement core used by the SPI top-level.
//   - A future RV32I core with ROM can drive the program/write inputs directly.
// -----------------------------------------------------------------------------
module agriasic_digital_programming_top #(
  parameter int unsigned ADC_WIDTH = 8
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // Compact programming interface intended for an RV32I firmware controller.
  input  logic                 prog_cfg_we_i,
  input  logic [1:0]           prog_cfg_addr_i,
  input  logic [7:0]           prog_cfg_data_i,
  input  logic                 prog_start_i,

  input  logic [ADC_WIDTH-1:0] adc_code_i,
  output logic                 conv_start_o,
  output logic                 exc_pol_o,
  output logic                 busy_o,
  output logic                 done_o,
  output logic [15:0]          result_o,

  // Expose the active programming state for debug and bring-up.
  output logic [3:0]           cfg_pair_log2_o,
  output logic [7:0]           cfg_settle_cycles_o,
  output logic [7:0]           cfg_exc_divider_o,
  output logic [7:0]           cfg_conv_cycles_o
);

  logic       start_pulse_q;
  logic       prog_start_q;
  logic [3:0] cfg_pair_log2_q;
  logic [7:0] cfg_settle_q;
  logic [7:0] cfg_divider_q;
  logic [7:0] cfg_conv_q;

  localparam logic [1:0] CFG_PAIR_LOG2 = 2'd0;
  localparam logic [1:0] CFG_SETTLE    = 2'd1;
  localparam logic [1:0] CFG_DIVIDER   = 2'd2;
  localparam logic [1:0] CFG_CONV      = 2'd3;

  assign cfg_pair_log2_o     = cfg_pair_log2_q;
  assign cfg_settle_cycles_o = cfg_settle_q;
  assign cfg_exc_divider_o   = cfg_divider_q;
  assign cfg_conv_cycles_o   = cfg_conv_q;

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) u_core (
    .clk                (clk),
    .rst_n              (rst_n),
    .start              (start_pulse_q),
    .cfg_pair_log2_i    (cfg_pair_log2_q),
    .cfg_settle_cycles_i(cfg_settle_q),
    .cfg_exc_divider_i  (cfg_divider_q),
    .cfg_conv_cycles_i  (cfg_conv_q),
    .adc_code_i         (adc_code_i),
    .conv_start_o       (conv_start_o),
    .exc_pol_o          (exc_pol_o),
    .busy_o             (busy_o),
    .done_o             (done_o),
    .result_o           (result_o)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_pulse_q   <= 1'b0;
      prog_start_q    <= 1'b0;
      cfg_pair_log2_q <= 4'd2;
      cfg_settle_q    <= 8'd2;
      cfg_divider_q   <= 8'd0;
      cfg_conv_q      <= 8'd1;
    end else begin
      start_pulse_q <= prog_start_i & ~prog_start_q;
      prog_start_q  <= prog_start_i;

      if (prog_cfg_we_i) begin
        unique case (prog_cfg_addr_i)
          CFG_PAIR_LOG2: cfg_pair_log2_q <= prog_cfg_data_i[3:0];
          CFG_SETTLE:    cfg_settle_q    <= prog_cfg_data_i;
          CFG_DIVIDER:   cfg_divider_q   <= prog_cfg_data_i;
          CFG_CONV:      cfg_conv_q      <= prog_cfg_data_i;
          default: begin
          end
        endcase
      end
    end
  end

endmodule