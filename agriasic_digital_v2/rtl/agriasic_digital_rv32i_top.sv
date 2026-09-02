// -----------------------------------------------------------------------------
// Module: agriasic_digital_rv32i_top
// Purpose:
//   Reference top-level RTL for the RV32I-programmable architecture.
//   This integrates the RV32I control shell with the existing measurement
//   engine so the RTL tree reflects the updated on-die controller partition.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module agriasic_digital_rv32i_top #(
  parameter int unsigned ADC_WIDTH = 8
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 start_i,
  input  logic [ADC_WIDTH-1:0] adc_code_i,

  output logic                 conv_start_o,
  output logic                 exc_pol_o,
  output logic                 busy_o,
  output logic                 done_o,
  output logic [15:0]          result_o,

  output logic [3:0]           cfg_pair_log2_o,
  output logic [7:0]           cfg_settle_cycles_o,
  output logic [7:0]           cfg_exc_divider_o,
  output logic [7:0]           cfg_conv_cycles_o
);

  logic shell_busy;
  logic shell_done;
  logic shell_start_pulse;
  logic shell_clear_errors;
  logic [15:0] shell_result;

  agriasic_rv32i_control_shell #(
    .ADC_WIDTH(ADC_WIDTH)
  ) u_control_shell (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .start_i               (start_i),
    .measurement_done_i    (done_o),
    .measurement_result_i  (result_o),
    .busy_o                (shell_busy),
    .done_o                (shell_done),
    .start_pulse_o         (shell_start_pulse),
    .clear_errors_o        (shell_clear_errors),
    .cfg_pair_log2_o       (cfg_pair_log2_o),
    .cfg_settle_cycles_o   (cfg_settle_cycles_o),
    .cfg_exc_divider_o     (cfg_exc_divider_o),
    .cfg_conv_cycles_o     (cfg_conv_cycles_o),
    .result_o              (shell_result)
  );

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) u_measurement_top (
    .clk                (clk),
    .rst_n              (rst_n),
    .start              (shell_start_pulse),
    .cfg_pair_log2_i    (cfg_pair_log2_o),
    .cfg_settle_cycles_i(cfg_settle_cycles_o),
    .cfg_exc_divider_i  (cfg_exc_divider_o),
    .cfg_conv_cycles_i   (cfg_conv_cycles_o),
    .adc_code_i         (adc_code_i),
    .conv_start_o       (conv_start_o),
    .exc_pol_o          (exc_pol_o),
    .busy_o             (busy_o),
    .done_o             (done_o),
    .result_o           (result_o)
  );

endmodule