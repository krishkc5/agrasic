// -----------------------------------------------------------------------------
// Module: agriasic_digital_rv32i_top
// Purpose:
//   Reference top-level RTL for the RV32I-programmable architecture.
//   This integrates the RV32I control shell (Ibex core + RISC-V debug module)
//   with the existing measurement engine so the RTL tree reflects the updated
//   on-die controller partition. Phase 2 added the five JTAG pins; Phase 3
//   added the boot strap, the four flash SPI pins and boot_fail_o.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module agriasic_digital_rv32i_top #(
  parameter int unsigned ADC_WIDTH         = 8,
  parameter int unsigned BOOT_DELAY_CYCLES = 800_000,  // flash power-up wait, shortened in simulation
  parameter bit          IMEM_PRELOADED    = 1'b0,     // simulation only: skip-boot releases the core
  parameter string       IMEM_INIT_FILE    = "agriasic_fw.hex"  // simulation only ("" = start empty)
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 start_i,

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
  output logic signed [15:0]   result_q_o,  // Rev 4.3 Phase 5: Q channel

  output logic [3:0]           cfg_pair_log2_o,
  output logic [7:0]           cfg_settle_cycles_o,
  output logic [13:0]          cfg_exc_divider_o,  // Rev 4.3 Phase 4.2: widened 8->14 bits, see GAP-1
  output logic [7:0]           cfg_conv_cycles_o,

  // JTAG debug port (Phase 2): 5-wire IEEE 1149.1 into the RISC-V debug
  // module inside the control shell. TRST_N is the TAP's own async reset;
  // it is independent of rst_n so a debugger can attach across a chip reset.
  input  logic                 jtag_tck_i,
  input  logic                 jtag_tms_i,
  input  logic                 jtag_trst_ni,
  input  logic                 jtag_tdi_i,
  output logic                 jtag_tdo_o,

  // SPI-flash boot (Phase 3): boot strap, 4-wire SPI master to the external
  // NOR flash, and a boot-failure flag (also readable in BOOT_STATUS).
  input  logic                 boot_sel_i,
  output logic                 flash_sck_o,
  output logic                 flash_cs_n_o,
  output logic                 flash_mosi_o,
  input  logic                 flash_miso_i,
  output logic                 boot_fail_o
);

  // Rev 4.3 Phase 2.1: rst_n is the raw, possibly-asynchronous chip pin.
  // Everything internal runs off rst_n_sync, released synchronously to clk.
  logic rst_n_sync;
  rst_sync u_rst_sync (
    .clk     (clk),
    .rst_n_i (rst_n),
    .rst_n_o (rst_n_sync)
  );

  logic shell_busy;
  logic shell_done;
  logic shell_start_pulse;
  logic shell_clear_errors;
  logic signed [15:0] shell_result_i;
  logic signed [15:0] shell_result_q;

  agriasic_rv32i_control_shell #(
    .ADC_WIDTH         (ADC_WIDTH),
    .BOOT_DELAY_CYCLES (BOOT_DELAY_CYCLES),
    .IMEM_PRELOADED    (IMEM_PRELOADED),
    .IMEM_INIT_FILE    (IMEM_INIT_FILE)
  ) u_control_shell (
    .clk                     (clk),
    .rst_n                   (rst_n_sync),
    .start_i                 (start_i),
    .measurement_done_i      (done_o),
    .measurement_result_i_i  (result_i_o),
    .measurement_result_q_i  (result_q_o),
    .busy_o                  (shell_busy),
    .done_o                  (shell_done),
    .start_pulse_o           (shell_start_pulse),
    .clear_errors_o          (shell_clear_errors),
    .cfg_pair_log2_o         (cfg_pair_log2_o),
    .cfg_settle_cycles_o     (cfg_settle_cycles_o),
    .cfg_exc_divider_o       (cfg_exc_divider_o),
    .cfg_conv_cycles_o       (cfg_conv_cycles_o),
    .result_i_o              (shell_result_i),
    .result_q_o              (shell_result_q),
    .jtag_tck_i              (jtag_tck_i),
    .jtag_tms_i              (jtag_tms_i),
    .jtag_trst_ni            (jtag_trst_ni),
    .jtag_tdi_i              (jtag_tdi_i),
    .jtag_tdo_o              (jtag_tdo_o),
    .boot_sel_i              (boot_sel_i),
    .flash_sck_o             (flash_sck_o),
    .flash_cs_n_o            (flash_cs_n_o),
    .flash_mosi_o            (flash_mosi_o),
    .flash_miso_i            (flash_miso_i),
    .boot_fail_o             (boot_fail_o)
  );

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) u_measurement_top (
    .clk                (clk),
    .rst_n              (rst_n_sync),
    .start              (shell_start_pulse),
    .cfg_pair_log2_i    (cfg_pair_log2_o),
    .cfg_settle_cycles_i(cfg_settle_cycles_o),
    .cfg_exc_divider_i  (cfg_exc_divider_o),
    .cfg_conv_cycles_i   (cfg_conv_cycles_o),
    .conv_start_o       (conv_start_o),
    .exc_drive_p_o      (exc_drive_p_o),
    .exc_drive_n_o      (exc_drive_n_o),
    .adc_enable_o       (adc_enable_o),
    .adc_sample_o       (adc_sample_o),
    .adc_dac_o          (adc_dac_o),
    .adc_comp_i         (adc_comp_i),
    .busy_o             (busy_o),
    .done_o             (done_o),
    .result_i_o         (result_i_o),
    .result_q_o         (result_q_o)
  );

endmodule
