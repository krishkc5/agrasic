// -----------------------------------------------------------------------------
// Module: excitation_ctrl
// Purpose:
//   Generates excitation polarity and settle qualification for the analog drive
//   stage.
//
// Functionality:
//   - Applies commanded phase changes through phase_value_i.
//   - Waits a programmable settle interval before asserting settled_o.
//   - Uses an internal divider to translate core clocks into settle ticks.
//
// Integration intent:
//   This module acts as the digital timing shim between FSM intent and analog
//   excitation behavior.
// -----------------------------------------------------------------------------
module excitation_ctrl (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       enable_i,
  input  logic       set_phase_i,
  input  logic       phase_value_i,
  input  logic [7:0] settle_cycles_i,
  input  logic [7:0] divider_i,
  output logic       polarity_o,
  output logic       settled_o,
  output logic       tick_o
);

  logic [7:0] div_cnt_q;
  logic [7:0] settle_cnt_q;

  // Divider-based tick generation used by settle timing.
  assign tick_o = (divider_i == 8'd0) ? 1'b1 : (div_cnt_q == divider_i);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      polarity_o   <= 1'b0;
      settled_o    <= 1'b1;
      div_cnt_q    <= 8'd0;
      settle_cnt_q <= 8'd0;
    end else if (!enable_i) begin
      // When disabled, hold a deterministic idle state.
      polarity_o   <= 1'b0;
      settled_o    <= 1'b1;
      div_cnt_q    <= 8'd0;
      settle_cnt_q <= 8'd0;
    end else begin
      if (divider_i != 8'd0) begin
        if (div_cnt_q == divider_i) begin
          div_cnt_q <= 8'd0;
        end else begin
          div_cnt_q <= div_cnt_q + 8'd1;
        end
      end

      if (set_phase_i) begin
        polarity_o <= phase_value_i;
        if (settle_cycles_i == 8'd0) begin
          settled_o    <= 1'b1;
          settle_cnt_q <= 8'd0;
        end else begin
          settled_o    <= 1'b0;
          settle_cnt_q <= settle_cycles_i;
        end
      end else if (!settled_o && tick_o) begin
        if (settle_cnt_q <= 8'd1) begin
          settle_cnt_q <= 8'd0;
          settled_o    <= 1'b1;
        end else begin
          settle_cnt_q <= settle_cnt_q - 8'd1;
        end
      end
    end
  end

endmodule
