// -----------------------------------------------------------------------------
// Module: agriasic_asic_top
// Purpose:
//   Chip-level top. Joins the synthesisable digital top to the analog
//   front-end macro and makes the eight AFE contract signals INTERNAL, which
//   is the point of this level: above here they are die-internal nets, not
//   pins, and the only analog things that leave are the electrodes, the
//   references and the supplies.
//
// NO PAD RING. This is the core-level top: no I/O cells, no ESD, no
// level shifters. Pads get inserted above this module once there is a pad
// library to instantiate.
//
// SYNTHESIS
//   The digital synthesis target is still agriasic_digital_rv32i_top -- that
//   is what timing/agriasic_digital_rv32i_top.sdc constrains, and nothing
//   here changes it. This module exists for top-level simulation and for
//   chip assembly.
//
//   If you do synthesise THIS module, agriasic_afe_top must be resolved from
//   lib/agriasic_afe_top.lib and rtl/analog/ must NOT be in the filelist:
//
//     read_lib       lib/agriasic_afe_top.lib      ;# or add to link_library
//     # do not analyze rtl/analog/*.sv
//     set_dont_touch [get_cells u_afe]
//
//   In that build the analog ports below are plain wires. The behavioural
//   build selects real-valued ports instead, via AGRIASIC_AFE_BEHAVIORAL.
//   This is the one place that define appears; see rtl/analog/README.md.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module agriasic_asic_top #(
  parameter int unsigned ADC_WIDTH         = 8,
  parameter int unsigned BOOT_DELAY_CYCLES = 800_000,
  parameter bit          IMEM_PRELOADED    = 1'b0,
  parameter string       IMEM_INIT_FILE    = "agriasic_fw.hex",
  parameter int unsigned ROM_WORDS         = 256,
  parameter int unsigned ROM_USED_WORDS    = 148,
  // Forwarded to the AFE behavioural model; ignored by the .lib view.
  parameter string       AFE_SH_STROBE_MODE      = "FREEZE_ON_RISE",
  parameter string       AFE_COMP_INVALID_POLICY = "HOLD"
) (
  // ---- Clock, reset, start --------------------------------------------------
  input  logic clk,
  input  logic rst_n,
  input  logic gpio_start_i,

  // ---- JTAG debug port ------------------------------------------------------
  input  logic gpio_jtag_tck_i,
  input  logic gpio_jtag_tms_i,
  input  logic gpio_jtag_trst_ni,
  input  logic gpio_jtag_tdi_i,
  output logic gpio_jtag_tdo_o,

  // ---- SPI-flash boot (chip is master) --------------------------------------
  input  logic gpio_boot_sel_i,
  output logic gpio_flash_sck_o,
  output logic gpio_flash_cs_n_o,
  output logic gpio_flash_mosi_o,
  input  logic gpio_flash_miso_i,
  output logic gpio_boot_fail_o,

  // ---- Host SPI port (chip is slave) ----------------------------------------
  input  logic gpio_spi_sclk_i,
  input  logic gpio_spi_cs_n_i,
  input  logic gpio_spi_mosi_i,
  output logic gpio_spi_miso_o,
  output logic gpio_spi_miso_oe_o,

  // ---- Analog boundary ------------------------------------------------------
  // Real-valued for the behavioural build, wires for synthesis. This is the
  // only ifdef in the file and the only one the swap needs.
`ifdef AGRIASIC_AFE_BEHAVIORAL
  output real  afe_e1_drive_o,    // excitation drive to electrode E1
  input  real  afe_e2_sense_i,    // dV sense +
  input  real  afe_e3_sense_i,    // dV sense -
  input  real  afe_e4_iin_i,      // return current into E4, amperes
  input  real  afe_vin_t_i,       // temperature divider tap
  input  real  afe_vdda_i,
  input  real  afe_vssa_i,
  input  real  afe_vrefh_i,
  input  real  afe_vrefl_i,
  input  real  afe_vcm_i,
  input  real  afe_ibias_i,
`else
  output wire  afe_e1_drive_o,
  input  wire  afe_e2_sense_i,
  input  wire  afe_e3_sense_i,
  input  wire  afe_e4_iin_i,
  input  wire  afe_vin_t_i,
  input  wire  afe_vdda_i,
  input  wire  afe_vssa_i,
  input  wire  afe_vrefh_i,
  input  wire  afe_vrefl_i,
  input  wire  afe_vcm_i,
  input  wire  afe_ibias_i,
`endif

  // ---- Observation ----------------------------------------------------------
  // NOT PADS. These mirror the digital top's dbg_* outputs so a bench can see
  // results without reaching into the hierarchy. On the real die they are
  // either dropped or muxed onto a debug port at pad insertion -- there are
  // far more bits here than a pad budget allows, and the host reads results
  // over SPI or JTAG instead (see docs/interface_contract.md, GAP-11).
  output logic               dbg_busy_o,
  output logic               dbg_done_o,
  output logic signed [15:0] dbg_result_dv_i_o,
  output logic signed [15:0] dbg_result_dv_q_o,
  output logic signed [15:0] dbg_result_cur_i_o,
  output logic signed [15:0] dbg_result_cur_q_o,
  output logic [3:0]         dbg_cfg_pair_log2_o,
  output logic [7:0]         dbg_cfg_settle_cycles_o,
  output logic [13:0]        dbg_cfg_exc_divider_o,
  output logic [7:0]         dbg_cfg_conv_cycles_o,
  output logic [7:0]         dbg_cfg_mux_settle_o,
  output logic [1:0]         dbg_cfg_amplitude_o
);

  // ---------------------------------------------------------------------------
  // The AFE contract, as die-internal nets. These eight are exactly the
  // signals of docs/interface_contract.md "Analog front-end interface
  // (Rev 5, tetrapolar)". Above this module they do not exist.
  // ---------------------------------------------------------------------------
  logic                 afe_conv_start;
  logic [ADC_WIDTH-1:0] afe_sine_code;
  logic [1:0]           afe_mux_sel;
  logic                 afe_adc_enable;
  logic                 afe_sample;
  logic [ADC_WIDTH-1:0] afe_adc_dac;
  logic                 afe_adc_comp;
  logic [2:0]           afe_tia_rf;

  // ---------------------------------------------------------------------------
  // Digital. Unchanged, and still the synthesis target in its own right.
  // ---------------------------------------------------------------------------
  agriasic_digital_rv32i_top #(
    .ADC_WIDTH         (ADC_WIDTH),
    .BOOT_DELAY_CYCLES (BOOT_DELAY_CYCLES),
    .IMEM_PRELOADED    (IMEM_PRELOADED),
    .IMEM_INIT_FILE    (IMEM_INIT_FILE),
    .ROM_WORDS         (ROM_WORDS),
    .ROM_USED_WORDS    (ROM_USED_WORDS)
  ) u_digital (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .gpio_start_i            (gpio_start_i),

    .afe_conv_start_o        (afe_conv_start),
    .afe_sine_code_o         (afe_sine_code),
    .afe_mux_sel_o           (afe_mux_sel),
    .afe_adc_enable_o        (afe_adc_enable),
    .afe_sample_o            (afe_sample),
    .afe_adc_dac_o           (afe_adc_dac),
    .afe_adc_comp_i          (afe_adc_comp),
    .afe_tia_rf_o            (afe_tia_rf),

    .dbg_busy_o              (dbg_busy_o),
    .dbg_done_o              (dbg_done_o),
    .dbg_result_dv_i_o       (dbg_result_dv_i_o),
    .dbg_result_dv_q_o       (dbg_result_dv_q_o),
    .dbg_result_cur_i_o      (dbg_result_cur_i_o),
    .dbg_result_cur_q_o      (dbg_result_cur_q_o),
    .dbg_cfg_pair_log2_o     (dbg_cfg_pair_log2_o),
    .dbg_cfg_settle_cycles_o (dbg_cfg_settle_cycles_o),
    .dbg_cfg_exc_divider_o   (dbg_cfg_exc_divider_o),
    .dbg_cfg_conv_cycles_o   (dbg_cfg_conv_cycles_o),
    .dbg_cfg_mux_settle_o    (dbg_cfg_mux_settle_o),
    .dbg_cfg_amplitude_o     (dbg_cfg_amplitude_o),

    .gpio_jtag_tck_i         (gpio_jtag_tck_i),
    .gpio_jtag_tms_i         (gpio_jtag_tms_i),
    .gpio_jtag_trst_ni       (gpio_jtag_trst_ni),
    .gpio_jtag_tdi_i         (gpio_jtag_tdi_i),
    .gpio_jtag_tdo_o         (gpio_jtag_tdo_o),

    .gpio_boot_sel_i         (gpio_boot_sel_i),
    .gpio_flash_sck_o        (gpio_flash_sck_o),
    .gpio_flash_cs_n_o       (gpio_flash_cs_n_o),
    .gpio_flash_mosi_o       (gpio_flash_mosi_o),
    .gpio_flash_miso_i       (gpio_flash_miso_i),
    .gpio_boot_fail_o        (gpio_boot_fail_o),

    .gpio_spi_sclk_i         (gpio_spi_sclk_i),
    .gpio_spi_cs_n_i         (gpio_spi_cs_n_i),
    .gpio_spi_mosi_i         (gpio_spi_mosi_i),
    .gpio_spi_miso_o         (gpio_spi_miso_o),
    .gpio_spi_miso_oe_o      (gpio_spi_miso_oe_o)
  );

  // ---------------------------------------------------------------------------
  // Analog front end: ONE macro. Behavioural here, a .lib blackbox in
  // synthesis. The parameter overrides are harmless in the .lib build because
  // the instance is resolved from the library, which carries no parameters.
  // ---------------------------------------------------------------------------
`ifdef AGRIASIC_AFE_BEHAVIORAL
  agriasic_afe_top #(
    .ADC_WIDTH           (ADC_WIDTH),
    .SH_STROBE_MODE      (AFE_SH_STROBE_MODE),
    .COMP_INVALID_POLICY (AFE_COMP_INVALID_POLICY)
  ) u_afe (
`else
  agriasic_afe_top u_afe (
`endif
    .afe_sine_code_i  (afe_sine_code),
    .afe_mux_sel_i    (afe_mux_sel),
    .afe_sample_i     (afe_sample),
    .afe_adc_enable_i (afe_adc_enable),
    .afe_adc_dac_i    (afe_adc_dac),
    .afe_adc_comp_o   (afe_adc_comp),
    .afe_conv_start_i (afe_conv_start),
    .afe_tia_rf_i     (afe_tia_rf),

    .e1_drive_o       (afe_e1_drive_o),
    .e2_sense_i       (afe_e2_sense_i),
    .e3_sense_i       (afe_e3_sense_i),
    .e4_iin_i         (afe_e4_iin_i),
    .vin_t_i          (afe_vin_t_i),

    .vdda_i           (afe_vdda_i),
    .vssa_i           (afe_vssa_i),
    .vrefh_i          (afe_vrefh_i),
    .vrefl_i          (afe_vrefl_i),
    .vcm_i            (afe_vcm_i),
    .ibias_i          (afe_ibias_i)
  );

endmodule
