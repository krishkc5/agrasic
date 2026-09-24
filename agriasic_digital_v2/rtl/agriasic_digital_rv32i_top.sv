// -----------------------------------------------------------------------------
// Module: agriasic_digital_rv32i_top
// Purpose:
//   Reference top-level RTL for the RV32I-programmable architecture.
//   This integrates the RV32I control shell (Ibex core + RISC-V debug module)
//   with the existing measurement engine so the RTL tree reflects the updated
//   on-die controller partition. Phase 2 added the five JTAG pins; Phase 3
//   added the boot strap, the four flash SPI pins and gpio_boot_fail_o.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module agriasic_digital_rv32i_top #(
  parameter int unsigned ADC_WIDTH         = 8,
  parameter int unsigned BOOT_DELAY_CYCLES = 800_000,  // flash power-up wait, shortened in simulation
  parameter bit          IMEM_PRELOADED    = 1'b0,     // simulation only: skip-boot releases the core
  parameter string       IMEM_INIT_FILE    = "agriasic_fw.hex", // simulation only ("" = start empty)
  parameter int unsigned ROM_WORDS         = 256,      // golden boot ROM depth
  parameter int unsigned ROM_USED_WORDS    = 148       // words the golden image occupies
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 gpio_start_i,

  output logic                 afe_conv_start_o,
  output logic [ADC_WIDTH-1:0] afe_sine_code_o,     // Rev 5: sine DAC code -> E1 drive buffer
  output logic [1:0]           afe_mux_sel_o,       // Rev 5: 0 = dV (PGA), 1 = I (TIA)
  output logic                 afe_adc_enable_o,
  output logic                 afe_sample_o,
  output logic [ADC_WIDTH-1:0] afe_adc_dac_o,
  input  logic                 afe_adc_comp_i,
  output logic                 dbg_busy_o,
  output logic                 dbg_done_o,
  output logic signed [15:0]   dbg_result_dv_i_o,   // Rev 5: dV in-phase
  output logic signed [15:0]   dbg_result_dv_q_o,   // Rev 5: dV quadrature
  output logic signed [15:0]   dbg_result_cur_i_o,  // Rev 5: current in-phase
  output logic signed [15:0]   dbg_result_cur_q_o,  // Rev 5: current quadrature

  output logic [3:0]           dbg_cfg_pair_log2_o,
  output logic [7:0]           dbg_cfg_settle_cycles_o,
  output logic [13:0]          dbg_cfg_exc_divider_o,  // Rev 4.3 Phase 4.2: widened 8->14 bits, see GAP-1
  output logic [7:0]           dbg_cfg_conv_cycles_o,
  output logic [7:0]           dbg_cfg_mux_settle_o,   // Rev 5: analog mux + S/H settling
  output logic [1:0]           dbg_cfg_amplitude_o,    // Rev 5: sine excursion select
  output logic [1:0]           afe_pga_gain_o,     // Rev 5: diff PGA gain (analog control)
  output logic [1:0]           afe_tia_rf_o,       // Rev 5: TIA feedback resistor (analog control)

  // JTAG debug port (Phase 2): 5-wire IEEE 1149.1 into the RISC-V debug
  // module inside the control shell. TRST_N is the TAP's own async reset;
  // it is independent of rst_n so a debugger can attach across a chip reset.
  input  logic                 gpio_jtag_tck_i,
  input  logic                 gpio_jtag_tms_i,
  input  logic                 gpio_jtag_trst_ni,
  input  logic                 gpio_jtag_tdi_i,
  output logic                 gpio_jtag_tdo_o,

  // SPI-flash boot (Phase 3): boot strap, 4-wire SPI master to the external
  // NOR flash, and a boot-failure flag (also readable in BOOT_STATUS).
  input  logic                 gpio_boot_sel_i,
  output logic                 gpio_flash_sck_o,
  output logic                 gpio_flash_cs_n_o,
  output logic                 gpio_flash_mosi_o,
  input  logic                 gpio_flash_miso_i,
  output logic                 gpio_boot_fail_o
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
  logic signed [15:0] shell_result_dv_i;
  logic signed [15:0] shell_result_dv_q;
  logic signed [15:0] shell_result_cur_i;
  logic signed [15:0] shell_result_cur_q;

  agriasic_rv32i_control_shell #(
    .ADC_WIDTH         (ADC_WIDTH),
    .BOOT_DELAY_CYCLES (BOOT_DELAY_CYCLES),
    .IMEM_PRELOADED    (IMEM_PRELOADED),
    .IMEM_INIT_FILE    (IMEM_INIT_FILE),
    .ROM_WORDS         (ROM_WORDS),
    .ROM_USED_WORDS    (ROM_USED_WORDS)
  ) u_control_shell (
    .clk                     (clk),
    .rst_n                   (rst_n_sync),
    .gpio_start_i                 (gpio_start_i),
    .measurement_done_i      (dbg_done_o),
    .measurement_result_dv_i_i  (dbg_result_dv_i_o),
    .measurement_result_dv_q_i  (dbg_result_dv_q_o),
    .measurement_result_cur_i_i (dbg_result_cur_i_o),
    .measurement_result_cur_q_i (dbg_result_cur_q_o),
    .busy_o                  (shell_busy),
    .done_o                  (shell_done),
    .start_pulse_o           (shell_start_pulse),
    .clear_errors_o          (shell_clear_errors),
    .cfg_pair_log2_o         (dbg_cfg_pair_log2_o),
    .cfg_settle_cycles_o     (dbg_cfg_settle_cycles_o),
    .cfg_exc_divider_o       (dbg_cfg_exc_divider_o),
    .cfg_conv_cycles_o       (dbg_cfg_conv_cycles_o),
    .cfg_mux_settle_o        (dbg_cfg_mux_settle_o),
    .cfg_amplitude_o         (dbg_cfg_amplitude_o),
    .afe_pga_gain_o          (afe_pga_gain_o),
    .afe_tia_rf_o            (afe_tia_rf_o),
    .result_dv_i_o           (shell_result_dv_i),
    .result_dv_q_o           (shell_result_dv_q),
    .result_cur_i_o          (shell_result_cur_i),
    .result_cur_q_o          (shell_result_cur_q),
    .gpio_jtag_tck_i              (gpio_jtag_tck_i),
    .gpio_jtag_tms_i              (gpio_jtag_tms_i),
    .gpio_jtag_trst_ni            (gpio_jtag_trst_ni),
    .gpio_jtag_tdi_i              (gpio_jtag_tdi_i),
    .gpio_jtag_tdo_o              (gpio_jtag_tdo_o),
    .gpio_boot_sel_i              (gpio_boot_sel_i),
    .gpio_flash_sck_o             (gpio_flash_sck_o),
    .gpio_flash_cs_n_o            (gpio_flash_cs_n_o),
    .gpio_flash_mosi_o            (gpio_flash_mosi_o),
    .gpio_flash_miso_i            (gpio_flash_miso_i),
    .gpio_boot_fail_o             (gpio_boot_fail_o)
  );

  agriasic_digital_top #(
    .ADC_WIDTH(ADC_WIDTH)
  ) u_measurement_top (
    .clk                (clk),
    .rst_n              (rst_n_sync),
    .start              (shell_start_pulse),
    .cfg_pair_log2_i    (dbg_cfg_pair_log2_o),
    .cfg_settle_cycles_i(dbg_cfg_settle_cycles_o),
    .cfg_exc_divider_i  (dbg_cfg_exc_divider_o),
    .cfg_conv_cycles_i   (dbg_cfg_conv_cycles_o),
    .cfg_mux_settle_i    (dbg_cfg_mux_settle_o),
    .cfg_amplitude_i     (dbg_cfg_amplitude_o),
    .afe_conv_start_o       (afe_conv_start_o),
    .afe_sine_code_o        (afe_sine_code_o),
    .afe_mux_sel_o          (afe_mux_sel_o),
    .afe_adc_enable_o       (afe_adc_enable_o),
    .afe_sample_o       (afe_sample_o),
    .afe_adc_dac_o          (afe_adc_dac_o),
    .afe_adc_comp_i         (afe_adc_comp_i),
    .busy_o             (dbg_busy_o),
    .done_o             (dbg_done_o),
    .result_dv_i_o      (dbg_result_dv_i_o),
    .result_dv_q_o      (dbg_result_dv_q_o),
    .result_cur_i_o     (dbg_result_cur_i_o),
    .result_cur_q_o     (dbg_result_cur_q_o)
  );

endmodule
