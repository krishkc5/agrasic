// -----------------------------------------------------------------------------
// Module: agriasic_rv32i_control_shell
// Purpose:
//   RV32I control shell for the AgriASIC measurement node. Wraps the lowRISC
//   Ibex RV32IM core, its instruction ROM, and the memory-mapped peripheral
//   bridge that drives the measurement engine.
//
//   Ibex replaces the Penn CIS 5710 pipelined core used through Rev 4.3 Phase
//   8 (that shell is preserved as agriasic_rv32i_control_shell.sv.penn, the
//   pre-RV32I microsequencer as .orig). The port list is IDENTICAL to both, so
//   agriasic_digital_rv32i_top requires no changes.
//
// Partition (policy vs. mechanism):
//   - Software here decides WHEN to measure, with WHICH configuration, and what
//     to do with results (calibration, averaging, compensation).
//   - The measurement FSM remains the real-time engine. Nothing cycle-accurate
//     lives in firmware: excitation polarity, settle qualification, conversion
//     trigger and accumulation are all hardware, so the sample instant has no
//     jitter and the +/- chop stays time-symmetric.
//
// Why Ibex:
//   The Penn core had no CSRs, traps, interrupts or debug hooks; out-of-map
//   accesses aliased silently and a JTAG debug module would have required
//   building all of that from scratch. Ibex brings the M-mode privileged
//   subset, RISC-V Debug Spec 0.13 support (debug_req_i, DmHaltAddr), and
//   riscv-dv/Spike verification collateral. Phase 1 was the core swap;
//   Phase 2 (this revision) adds the debug module.
//
// Debug (Phase 2):
//   pulp-platform riscv-dbg: dmi_jtag (5-wire JTAG TAP + DTM) -> dm_top
//   (Debug Module, Debug Spec 0.13). The DM is a slave at 0x1A11_0000 on
//   BOTH core ports through agriasic_rv32i_bus (instruction port fetches the
//   debug ROM / program buffer at DmHaltAddr; data port reaches data0/1 and
//   the halted/resume flags), its debug_req_o drives Ibex's debug_req_i, and
//   its system-bus master (SBA) is a third bus master so OpenOCD can `load`
//   firmware straight into IMEM and inspect RAM/MMIO without the hart.
//   ndmreset (dmcontrol.ndmreset) resets the core and the peripheral bridge,
//   never the DM or the JTAG TAP. IMEM contents survive ndmreset.
//
//   Address map (flat, see agriasic_rv32i_bus.sv): IMEM 0x0000_0000,
//   DMEM 0x0001_0000, DM 0x1A11_0000, MMIO 0x8000_0000. DMEM moved from 0
//   to 0x0001_0000 so a debugger's single address space has no overlap
//   between the two memories (firmware SP / result addresses moved with it).
//
// Boot:
//   agriasic_spi_boot is a fourth bus master, and the IMEM SRAM is loaded
//   from one of two sources selected by the BOOT_SEL strap:
//     0 (default)  the GOLDEN image, shadow-loaded from the on-die
//                  synthesized boot ROM (agriasic_boot_rom) -- a bare chip
//                  with no flash and no host starts and runs on its own
//     1            an image from external SPI flash, header + CRC-32 checked
//   Either way the core fetches from the SRAM, never from the ROM, so IMEM
//   stays writable after boot: a debugger can halt, patch a constant over
//   JTAG and resume without rebuilding or reflashing. That is why this is a
//   shadow-load and not a fetch-path mux -- the mux would have cost timing on
//   the fetch path AND given up patchability in ROM mode.
//   The core is held in reset until fw_valid AND gpio_start_i are both high.
//   gpio_boot_fail_o is raised on a bad magic/length/CRC/bus error (a ROM copy can
//   only fail on a bus error). BOOT_CTRL overrides the strap in both
//   directions. After boot the same SPI engine is a firmware peripheral
//   (SPI_CTRL/SPI_DATA) for reflashing.
//
// Run control:
//   The core is held in reset while gpio_start_i is low or fw_valid is low
//   (reported to the DM as `unavailable`, so a debugger must raise gpio_start_i
//   and release the boot before it can halt the hart) and boots from
//   boot_addr_i + 0x80 = 0x80 when gpio_start_i is asserted (Ibex convention: the
//   32-entry trap vector table occupies 0x00-0x7F, mtvec = boot_addr_i).
//   Holding the core in reset between runs is also the power-saving state.
//
// Sleep during a measurement (replaces the Rev 4.3 Phase 2.2 core_clk_en):
//   Ibex has no clock-enable input. Firmware writes CTRL.START and executes
//   wfi; the bridge's sticky DONE latch is fed to irq_fast_i[0]. Ibex leaves
//   SLEEP when any interrupt enabled in mie becomes pending, independent of
//   mstatus.MIE (ibex_controller.sv SLEEP state), so with mie.fast0 set and
//   MIE clear the core resumes after the wfi without taking a trap. While
//   asleep it issues no fetches; core_sleep_o is exported below for a future
//   integrated clock gate. Phase 1 does NOT gate clk (MAS section 8.1).
//
// Firmware completion:
//   The Penn core's ecall drove halt -> done_o. On Ibex ecall is a trap, so
//   firmware instead writes CTRL.FW_DONE (sticky) and parks in wfi.
//   done_o = FW_DONE; busy_o = running and not done.
//
// Register file:
//   Define AGRIASIC_LATCH_REGFILE for the ASIC synthesis run to get Ibex's
//   latch-based register file (roughly half the area of the flop file). It is
//   deliberately NOT tied to SYNTHESIS: Verilator cannot simulate the latch
//   file, and power/run_synthesis.py must synthesize the same hierarchy the
//   power testbench simulated so register activity can be cross-checked.
//
// Memory interfaces:
//   Ibex uses an OBI-style req/gnt/rvalid handshake. Both memories complete
//   every access in one cycle, so gnt = req and rvalid = registered req; the
//   existing agriasic_imem / agriasic_dmem wrappers are unchanged. Fetches
//   beyond the ROM and data accesses outside RAM/MMIO return err, which Ibex
//   converts into an access-fault trap.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ns

module agriasic_rv32i_control_shell #(
  parameter int unsigned ADC_WIDTH         = 8,
  parameter int unsigned BOOT_DELAY_CYCLES = 800_000,  // flash power-up wait (~5 ms at 160 MHz)
  parameter int unsigned ROM_WORDS         = 256,      // golden boot ROM depth
  parameter int unsigned ROM_USED_WORDS    = 148,      // words the golden image occupies
  parameter bit          IMEM_PRELOADED    = 1'b0,     // simulation: IMEM filled by $readmemh
  parameter string       IMEM_INIT_FILE    = "agriasic_fw.hex"  // simulation preload ("" = none)
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 gpio_start_i,
  input  logic                 measurement_done_i,
  // Rev 5: two channels. dV = differential voltage (PGA on E2/E3),
  // cur = return current (TIA on E4). Z(f) = dV(f) / I(f), computed host-side.
  input  logic signed [15:0]   measurement_result_dv_i_i,
  input  logic signed [15:0]   measurement_result_dv_q_i,
  input  logic signed [15:0]   measurement_result_cur_i_i,
  input  logic signed [15:0]   measurement_result_cur_q_i,

  output logic                 busy_o,
  output logic                 done_o,
  output logic                 start_pulse_o,
  output logic                 clear_errors_o,

  output logic [3:0]           cfg_pair_log2_o,
  output logic [7:0]           cfg_settle_cycles_o,
  output logic [13:0]          cfg_exc_divider_o,  // Rev 4.3 Phase 4.2: widened 8->14 bits, see GAP-1
  output logic [7:0]           cfg_conv_cycles_o,
  output logic [7:0]           cfg_mux_settle_o,   // Rev 5
  output logic [1:0]           cfg_amplitude_o,    // Rev 5
  output logic [1:0]           afe_pga_gain_o,     // Rev 5 (analog control)
  output logic [1:0]           afe_tia_rf_o,       // Rev 5 (analog control)
  output logic signed [15:0]   result_dv_i_o,
  output logic signed [15:0]   result_dv_q_o,
  output logic signed [15:0]   result_cur_i_o,
  output logic signed [15:0]   result_cur_q_o,

  // JTAG (Phase 2): 5-wire, IEEE 1149.1 TAP inside dmi_jtag
  input  logic                 gpio_jtag_tck_i,
  input  logic                 gpio_jtag_tms_i,
  input  logic                 gpio_jtag_trst_ni,
  input  logic                 gpio_jtag_tdi_i,
  output logic                 gpio_jtag_tdo_o,

  // Boot from SPI flash (Phase 3)
  input  logic                 gpio_boot_sel_i,      // 1: boot from flash, 0: wait for release
  output logic                 gpio_flash_sck_o,
  output logic                 gpio_flash_cs_n_o,
  output logic                 gpio_flash_mosi_o,
  input  logic                 gpio_flash_miso_i,
  // Host SPI port (closes GAP-11). Chip is the SLAVE: an external host drives
  // SCK/CS_N/MOSI and reads MISO. Deliberately NOT shared with the flash pins
  // above -- every wire runs the opposite direction there.
  input  logic                 gpio_spi_sclk_i,
  input  logic                 gpio_spi_cs_n_i,
  input  logic                 gpio_spi_mosi_i,
  output logic                 gpio_spi_miso_o,
  output logic                 gpio_spi_miso_oe_o,

  output logic                 gpio_boot_fail_o
);

  // ADC_WIDTH is retained for interface compatibility; the control core does
  // not touch ADC samples directly, only the accumulated result.
  // Sized to the measured firmware, not to a round number: with no SRAM
  // compiler these are flop arrays, and both the flops and the read mux
  // scale with depth (see agriasic_imem.sv). The image is 592 B and the
  // data footprint 100 B, measured by the memory audit flow.
  localparam int unsigned IMEM_WORDS = 256;   // 1 KB program memory
  localparam int unsigned DMEM_WORDS = 128;   // 512 B scratch RAM
  localparam int unsigned IMEM_BYTES = IMEM_WORDS * 4;

  // Size consistency. Both failure modes below are silent in hardware -- the
  // chip boots a truncated image and behaves oddly rather than reporting
  // anything -- so check them where a human will see it. agriasic_boot_rom
  // carries the matching check against its own generated table, and
  // fw/build.sh enforces the image bound at build time.
`ifndef SYNTHESIS
  initial begin
    if (ROM_USED_WORDS > ROM_WORDS)
      $fatal(1, "control_shell: ROM_USED_WORDS (%0d) exceeds ROM_WORDS (%0d)",
             ROM_USED_WORDS, ROM_WORDS);
    if (ROM_USED_WORDS > IMEM_WORDS)
      $fatal(1, "control_shell: golden image (%0d words) does not fit IMEM (%0d words)",
             ROM_USED_WORDS, IMEM_WORDS);
  end
`endif
  localparam int unsigned DMEM_BYTES = DMEM_WORDS * 4;
  localparam logic [31:0] DMEM_BASE   = 32'h0001_0000;
  localparam logic [31:0] PERIPH_BASE = 32'h8000_0000;

  // RISC-V debug module window. Halt/resume/exception offsets come from the
  // riscv-dbg debug ROM (dm_pkg: 0x800 / 0x808 / 0x810) and MUST match what
  // Ibex is told below.
  localparam logic [31:0] DM_BASE_ADDR      = 32'h1A11_0000;
  localparam int unsigned DM_ADDR_MASK      = 32'h0000_0FFF;
  localparam int unsigned DM_HALT_ADDR      = DM_BASE_ADDR + dm::HaltAddress[31:0];
  localparam int unsigned DM_EXCEPTION_ADDR = DM_BASE_ADDR + dm::ExceptionAddress[31:0];
  localparam logic [31:0] JTAG_IDCODE       = 32'h1434_1001;  // version 1, part 0x4341, LSB must be 1

  localparam dm::hartinfo_t HART_INFO = '{
    zero1:      '0,
    nscratch:   2,              // Ibex has dscratch0/1
    zero0:      '0,
    dataaccess: 1'b1,           // data0/1 are memory mapped in the DM
    datasize:   dm::DataCount,
    dataaddr:   dm::DataAddr
  };

  // --------------------------------------------------------------------------
  // Core reset control
  //
  // Registering !gpio_start_i gives a glitch-free, synchronously released reset
  // for the core. Ibex resets asynchronously (rst_ni), so the flop output is
  // used directly.
  // --------------------------------------------------------------------------
  logic core_rst;

  logic fw_valid;

`ifndef SYNTHESIS
  // Simulation only: together with rst_sync's initial values this gives the
  // core's reset (core_rst_n below) a real falling edge at time zero, which
  // Ibex's gated-clock async-reset flops need under Verilator's 2-state init.
  initial core_rst = 1'b0;
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      core_rst <= 1'b1;
    end else begin
      core_rst <= !(gpio_start_i && fw_valid);
    end
  end

  // ndmreset from the debugger resets the "non-debug module": core and the
  // peripheral bridge (config registers, sticky flags). The DM, the TAP and
  // the memories are untouched, so a debugger can `load` then ndmreset.
  logic ndmreset;
  logic ndmreset_q;
  wire  sys_rst_n  = rst_n && !ndmreset;
  wire  core_rst_n = sys_rst_n && !core_rst;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ndmreset_q <= 1'b0;
    else        ndmreset_q <= ndmreset;
  end
  // One-cycle acknowledge after the reset has actually been applied.
  wire ndmreset_ack = ndmreset && !ndmreset_q;

  // --------------------------------------------------------------------------
  // Core <-> memory wiring
  // --------------------------------------------------------------------------
  logic        instr_req;
  logic        instr_gnt;
  logic        instr_rvalid;
  logic        instr_err;
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;

  logic        data_req;
  logic        data_gnt;
  logic        data_rvalid;
  logic        data_we;
  logic [3:0]  data_be;
  logic [31:0] data_addr;
  logic [31:0] data_wdata;
  logic [31:0] data_rdata;
  logic        data_err;

  logic        fw_done;
  logic        trap_seen;
  logic        meas_done_irq;
  logic        core_sleep;
  logic        debug_req;

  // Bus <-> slaves
  logic        imem_ce;
  logic [3:0]  imem_we;
  logic [31:0] imem_addr, imem_wdata, imem_rdata;
  logic        mmio_req, mmio_gnt, mmio_rvalid, mmio_we, mmio_err;
  logic [3:0]  mmio_be;
  logic [31:0] mmio_addr, mmio_wdata, mmio_rdata;
  logic        dm_req, dm_we;
  logic [3:0]  dm_be;
  logic [31:0] dm_addr, dm_wdata, dm_rdata;

  // Debug module system-bus master
  logic        sba_req, sba_gnt, sba_rvalid, sba_we, sba_err;
  logic [3:0]  sba_be;
  logic [31:0] sba_addr, sba_wdata, sba_rdata;

  // Boot loader bus master
  logic        boot_req, boot_gnt, boot_rvalid, boot_we, boot_err;
  logic        host_req, host_gnt, host_rvalid, host_we, host_err;
  logic [3:0]  host_be;
  logic [31:0] host_addr, host_wdata, host_rdata;
  logic [3:0]  boot_be;
  logic [31:0] boot_addr, boot_wdata, boot_rdata;

  // Boot / SPI-master register plumbing
  logic        boot_release, boot_retry, boot_rom_req, spi_ctrl_we, spi_data_we;
  logic [31:0] rom_addr, rom_data;
  logic [15:0] spi_ctrl_wdata;
  logic [7:0]  spi_data_wdata, spi_rx;
  logic [31:0] boot_status, spi_ctrl_rd, spi_status;

  // DMI between the JTAG DTM and the DM
  logic          dmi_rst_n, dmi_req_valid, dmi_req_ready, dmi_resp_valid, dmi_resp_ready;
  dm::dmi_req_t  dmi_req;
  dm::dmi_resp_t dmi_resp;

  // --------------------------------------------------------------------------
  // Ibex core
  // --------------------------------------------------------------------------
  ibex_top #(
    .RV32E           (1'b0),
    .RV32M           (ibex_pkg::RV32MFast),     // 1-cycle mul, iterative div
    .RV32B           (ibex_pkg::RV32BNone),
    .RV32ZC          (ibex_pkg::RV32Zca),       // C cannot be disabled; minimal subset
    // ASIC: latch file is ~half the area. Simulation must use the FF file
    // (Ibex forbids latches under Verilator); see the header note.
`ifdef AGRIASIC_LATCH_REGFILE
    .RegFile         (ibex_pkg::RegFileLatch),
`else
    .RegFile         (ibex_pkg::RegFileFF),
`endif
    .BranchTargetALU (1'b1),
    .WritebackStage  (1'b1),                    // 3-stage: loads do not stall the pipe
    .ICache          (1'b0),
    .ICacheECC       (1'b0),
    .BranchPredictor (1'b0),
    .DbgTriggerEn    (1'b0),
    .SecureIbex      (1'b0),
    .PMPEnable       (1'b0),
    .MHPMCounterNum  (0),
    .DmBaseAddr      (DM_BASE_ADDR),
    .DmAddrMask      (DM_ADDR_MASK),
    .DmHaltAddr      (DM_HALT_ADDR),
    .DmExceptionAddr (DM_EXCEPTION_ADDR)
  ) u_core (
    .clk_i                  (clk),
    .rst_ni                 (core_rst_n),
    .test_en_i              (1'b0),
    .scan_rst_ni            (core_rst_n),
    .ram_cfg_icache_tag_i   ('0),
    .ram_cfg_icache_tag_o   (),
    .ram_cfg_icache_data_i  ('0),
    .ram_cfg_icache_data_o  (),
    .cheriot_enable_i       (ibex_pkg::IbexMuBiOff),
    .hart_id_i              (32'd0),
    .boot_addr_i            (32'h0000_0000),
    .trvk_heap_base_addr_i  (32'd0),

    // Instruction port -> bus (IMEM, debug ROM)
    .instr_req_o            (instr_req),
    .instr_gnt_i            (instr_gnt),
    .instr_rvalid_i         (instr_rvalid),
    .instr_addr_o           (instr_addr),
    .instr_rdata_i          (instr_rdata),
    .instr_rdata_intg_i     (7'd0),
    .instr_err_i            (instr_err),

    // Data port -> bus (IMEM, DMEM/MMIO, DM)
    .data_req_o             (data_req),
    .data_gnt_i             (data_gnt),
    .data_rvalid_i          (data_rvalid),
    .data_we_o              (data_we),
    .data_be_o              (data_be),
    .data_addr_o            (data_addr),
    .data_wdata_o           (data_wdata),
    .data_wdata_intg_o      (),
    .data_tag_o             (),
    .data_rdata_i           (data_rdata),
    .data_rdata_intg_i      (7'd0),
    .data_tag_i             (1'b0),
    .data_err_i             (data_err),

    // CHERIoT revocation bitmap port: unused
    .trvk_revbm_req_o       (),
    .trvk_revbm_gnt_i       (1'b0),
    .trvk_revbm_rvalid_i    (1'b0),
    .trvk_revbm_addr_o      (),
    .trvk_revbm_rdata_i     (32'd0),
    .trvk_revbm_rdata_intg_i(7'd0),
    .trvk_revbm_err_i       (1'b0),

    // Interrupts: fast0 = measurement DONE (wfi wake-up)
    .irq_software_i         (1'b0),
    .irq_timer_i            (1'b0),
    .irq_external_i         (1'b0),
    .irq_fast_i             ({14'd0, meas_done_irq}),
    .irq_nm_i               (1'b0),

    // Scrambling / security: unused
    .scramble_key_valid_i   (1'b0),
    .scramble_key_i         ('0),
    .scramble_nonce_i       ('0),
    .scramble_req_o         (),

    // Debug
    .debug_req_i            (debug_req),
    .crash_dump_o           (),
    .double_fault_seen_o    (),

    .fetch_enable_i         (ibex_pkg::IbexMuBiOn),
    .mcounteren_writable_i  (ibex_pkg::IbexMuBiOn),
    .alert_minor_o          (),
    .alert_major_internal_o (),
    .alert_major_bus_o      (),
    .core_sleep_o           (core_sleep),

    // Lockstep shadow outputs: unused (SecureIbex = 0)
    .lockstep_cmp_en_o      (),
    .data_req_shadow_o      (),
    .data_we_shadow_o       (),
    .data_be_shadow_o       (),
    .data_addr_shadow_o     (),
    .data_wdata_shadow_o    (),
    .data_wdata_intg_shadow_o(),
    .instr_req_shadow_o     (),
    .instr_addr_shadow_o    ()
  );

  // --------------------------------------------------------------------------
  // Interconnect
  // --------------------------------------------------------------------------
  agriasic_rv32i_bus #(
    .IMEM_BYTES   (IMEM_BYTES),
    .DMEM_BASE    (DMEM_BASE),
    .DMEM_BYTES   (DMEM_BYTES),
    .PERIPH_BASE  (PERIPH_BASE),
    .PERIPH_BYTES (32'h40),
    .DM_BASE      (DM_BASE_ADDR),
    .DM_BYTES     (DM_ADDR_MASK + 1)
  ) u_bus (
    .clk            (clk),
    .rst_n          (rst_n),
    .instr_req_i    (instr_req),
    .instr_addr_i   (instr_addr),
    .instr_gnt_o    (instr_gnt),
    .instr_rvalid_o (instr_rvalid),
    .instr_rdata_o  (instr_rdata),
    .instr_err_o    (instr_err),
    .data_req_i     (data_req),
    .data_we_i      (data_we),
    .data_be_i      (data_be),
    .data_addr_i    (data_addr),
    .data_wdata_i   (data_wdata),
    .data_gnt_o     (data_gnt),
    .data_rvalid_o  (data_rvalid),
    .data_rdata_o   (data_rdata),
    .data_err_o     (data_err),
    .sba_req_i      (sba_req),
    .sba_we_i       (sba_we),
    .sba_be_i       (sba_be),
    .sba_addr_i     (sba_addr),
    .sba_wdata_i    (sba_wdata),
    .sba_gnt_o      (sba_gnt),
    .sba_rvalid_o   (sba_rvalid),
    .sba_rdata_o    (sba_rdata),
    .sba_err_o      (sba_err),
    .boot_req_i     (boot_req),
    .boot_we_i      (boot_we),
    .boot_be_i      (boot_be),
    .boot_addr_i    (boot_addr),
    .boot_wdata_i   (boot_wdata),
    .boot_gnt_o     (boot_gnt),
    .boot_rvalid_o  (boot_rvalid),
    .boot_rdata_o   (boot_rdata),
    .boot_err_o     (boot_err),
    .host_req_i     (host_req),
    .host_we_i      (host_we),
    .host_be_i      (host_be),
    .host_addr_i    (host_addr),
    .host_wdata_i   (host_wdata),
    .host_gnt_o     (host_gnt),
    .host_rvalid_o  (host_rvalid),
    .host_rdata_o   (host_rdata),
    .host_err_o     (host_err),
    .imem_ce_o      (imem_ce),
    .imem_we_o      (imem_we),
    .imem_addr_o    (imem_addr),
    .imem_wdata_o   (imem_wdata),
    .imem_rdata_i   (imem_rdata),
    .mmio_req_o     (mmio_req),
    .mmio_we_o      (mmio_we),
    .mmio_be_o      (mmio_be),
    .mmio_addr_o    (mmio_addr),
    .mmio_wdata_o   (mmio_wdata),
    .mmio_gnt_i     (mmio_gnt),
    .mmio_rvalid_i  (mmio_rvalid),
    .mmio_rdata_i   (mmio_rdata),
    .mmio_err_i     (mmio_err),
    .dm_req_o       (dm_req),
    .dm_we_o        (dm_we),
    .dm_be_o        (dm_be),
    .dm_addr_o      (dm_addr),
    .dm_wdata_o     (dm_wdata),
    .dm_rdata_i     (dm_rdata)
  );

  // --------------------------------------------------------------------------
  // Program memory
  //
  // Its output register IS the fetch data register: address captured under
  // ce, data valid the following cycle = the bus's rvalid. Loadable through
  // the same port (debugger SBA or the core's data port) -- the bus
  // guarantees one access per cycle.
  // --------------------------------------------------------------------------
  agriasic_imem #(
    .NUM_WORDS(IMEM_WORDS),
    .INIT_FILE(IMEM_INIT_FILE)
  ) u_imem (
    .clk    (clk),
    .rst_n  (rst_n),
    .ce_i   (imem_ce),
    .we_i   (imem_we),
    .addr_i (imem_addr),
    .din_i  (imem_wdata),
    .dout_o (imem_rdata)
  );

  // --------------------------------------------------------------------------
  // Scratch RAM plus the peripheral window (reset by ndmreset too).
  // --------------------------------------------------------------------------
  agriasic_rv32i_mmio #(
    .RAM_WORDS(DMEM_WORDS),
    .RAM_BASE (DMEM_BASE)
  ) u_mmio (
    .clk                 (clk),
    .rst_n               (sys_rst_n),
    .run_clear_i         (core_rst),
    .data_req_i          (mmio_req),
    .data_gnt_o          (mmio_gnt),
    .data_rvalid_o       (mmio_rvalid),
    .data_we_i           (mmio_we),
    .data_be_i           (mmio_be),
    .data_addr_i         (mmio_addr),
    .data_wdata_i        (mmio_wdata),
    .data_rdata_o        (mmio_rdata),
    .data_err_o          (mmio_err),
    .start_pulse_o       (start_pulse_o),
    .clear_errors_o      (clear_errors_o),
    .cfg_pair_log2_o     (cfg_pair_log2_o),
    .cfg_settle_cycles_o (cfg_settle_cycles_o),
    .cfg_exc_divider_o   (cfg_exc_divider_o),
    .cfg_conv_cycles_o   (cfg_conv_cycles_o),
    .cfg_mux_settle_o    (cfg_mux_settle_o),
    .cfg_amplitude_o     (cfg_amplitude_o),
    .cfg_pga_gain_o      (afe_pga_gain_o),
    .cfg_tia_rf_o        (afe_tia_rf_o),
    .fw_done_o           (fw_done),
    .trap_seen_o         (trap_seen),
    .meas_done_irq_o     (meas_done_irq),
    .done_i              (measurement_done_i),
    .result_dv_i_i       (measurement_result_dv_i_i),
    .result_dv_q_i       (measurement_result_dv_q_i),
    .result_cur_i_i      (measurement_result_cur_i_i),
    .result_cur_q_i      (measurement_result_cur_q_i),
    .boot_release_o      (boot_release),
    .boot_retry_o        (boot_retry),
    .boot_rom_o          (boot_rom_req),
    .spi_ctrl_we_o       (spi_ctrl_we),
    .spi_ctrl_wdata_o    (spi_ctrl_wdata),
    .spi_data_we_o       (spi_data_we),
    .spi_data_wdata_o    (spi_data_wdata),
    .boot_status_i       (boot_status),
    .spi_ctrl_i          (spi_ctrl_rd),
    .spi_rx_i            (spi_rx),
    .spi_status_i        (spi_status)
  );

  // --------------------------------------------------------------------------
  // SPI-flash boot loader (Phase 3). Resets with the chip, never with
  // ndmreset: the debugger's reset must not restart a flash boot underneath
  // an image it just loaded.
  // --------------------------------------------------------------------------
  // Golden image, synthesized as a constant table (generated from
  // fw/golden/agriasic_fw_golden.hex by fw/gen_boot_rom.py). Combinational:
  // the copier registers the data on its way into the SRAM.
  // ---------------------------------------------------------------------------
  // Host SPI port: bus master M4. Shaped like the debug SBA -- an external
  // agent with its own master port, reading results out of DMEM while the core
  // sleeps. Permissions (DMEM + MMIO only) are enforced in the interconnect.
  // Runs off sys_rst_n so a debugger's ndmreset also resets the host port,
  // matching the peripheral bridge it talks to.
  // ---------------------------------------------------------------------------
  agriasic_spi_host u_spi_host (
    .clk          (clk),
    .rst_n        (sys_rst_n),
    .sclk_i       (gpio_spi_sclk_i),
    .cs_n_i       (gpio_spi_cs_n_i),
    .mosi_i       (gpio_spi_mosi_i),
    .miso_o       (gpio_spi_miso_o),
    .miso_oe_o    (gpio_spi_miso_oe_o),
    .bus_req_o    (host_req),
    .bus_we_o     (host_we),
    .bus_be_o     (host_be),
    .bus_addr_o   (host_addr),
    .bus_wdata_o  (host_wdata),
    .bus_gnt_i    (host_gnt),
    .bus_rvalid_i (host_rvalid),
    .bus_rdata_i  (host_rdata),
    .bus_err_i    (host_err)
  );

  agriasic_boot_rom #(
    .NUM_WORDS  (ROM_WORDS),
    .USED_WORDS (ROM_USED_WORDS)
  ) u_boot_rom (
    .addr_i (rom_addr),
    .data_o (rom_data)
  );

  agriasic_spi_boot #(
    .IMEM_BYTES        (IMEM_BYTES),
    .BOOT_DELAY_CYCLES (BOOT_DELAY_CYCLES),
    .IMEM_PRELOADED    (IMEM_PRELOADED),
    .ROM_USED_WORDS    (ROM_USED_WORDS)
  ) u_boot (
    .clk              (clk),
    .rst_n            (rst_n),
    .boot_sel_i       (gpio_boot_sel_i),
    .rom_addr_o       (rom_addr),
    .rom_data_i       (rom_data),
    .spi_sck_o        (gpio_flash_sck_o),
    .spi_cs_n_o       (gpio_flash_cs_n_o),
    .spi_mosi_o       (gpio_flash_mosi_o),
    .spi_miso_i       (gpio_flash_miso_i),
    .bus_req_o        (boot_req),
    .bus_we_o         (boot_we),
    .bus_be_o         (boot_be),
    .bus_addr_o       (boot_addr),
    .bus_wdata_o      (boot_wdata),
    .bus_gnt_i        (boot_gnt),
    .bus_rvalid_i     (boot_rvalid),
    .bus_rdata_i      (boot_rdata),
    .bus_err_i        (boot_err),
    .fw_valid_o       (fw_valid),
    .boot_fail_o      (gpio_boot_fail_o),
    .ctrl_release_i   (boot_release),
    .ctrl_retry_i     (boot_retry),
    .ctrl_boot_rom_i  (boot_rom_req),
    .spi_ctrl_we_i    (spi_ctrl_we),
    .spi_ctrl_wdata_i (spi_ctrl_wdata),
    .spi_data_we_i    (spi_data_we),
    .spi_data_wdata_i (spi_data_wdata),
    .boot_status_o    (boot_status),
    .spi_ctrl_o       (spi_ctrl_rd),
    .spi_rx_o         (spi_rx),
    .spi_status_o     (spi_status)
  );

  // --------------------------------------------------------------------------
  // JTAG DTM and Debug Module (riscv-dbg)
  // --------------------------------------------------------------------------
  dmi_jtag #(
    .IdcodeValue (JTAG_IDCODE)
  ) u_dtm (
    .clk_i            (clk),
    .rst_ni           (rst_n),
    .testmode_i       (1'b0),
    .dmi_rst_no       (dmi_rst_n),
    .dmi_req_o        (dmi_req),
    .dmi_req_valid_o  (dmi_req_valid),
    .dmi_req_ready_i  (dmi_req_ready),
    .dmi_resp_i       (dmi_resp),
    .dmi_resp_ready_o (dmi_resp_ready),
    .dmi_resp_valid_i (dmi_resp_valid),
    .tck_i            (gpio_jtag_tck_i),
    .tms_i            (gpio_jtag_tms_i),
    .trst_ni          (gpio_jtag_trst_ni),
    .td_i             (gpio_jtag_tdi_i),
    .td_o             (gpio_jtag_tdo_o),
    .tdo_oe_o         ()
  );

  dm_top #(
    .NrHarts         (1),
    .BusWidth        (32),
    .DmBaseAddress   (DM_BASE_ADDR),
    .SelectableHarts (1'b1),
    .ReadByteEnable  (1)
  ) u_dm (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .next_dm_addr_i       (32'd0),
    .testmode_i           (1'b0),
    .ndmreset_o           (ndmreset),
    .ndmreset_ack_i       (ndmreset_ack),
    .dmactive_o           (),
    .debug_req_o          (debug_req),
    .unavailable_i        (core_rst),        // hart held in reset while gpio_start_i is low
    .hartinfo_i           (HART_INFO),
    // Slave: debug ROM / program buffer / data0..1 / flags, via the bus
    .slave_req_i          (dm_req),
    .slave_we_i           (dm_we),
    .slave_addr_i         (dm_addr),
    .slave_be_i           (dm_be),
    .slave_wdata_i        (dm_wdata),
    .slave_rdata_o        (dm_rdata),
    // Master: system bus access, a bus master like the core's data port
    .master_req_o         (sba_req),
    .master_add_o         (sba_addr),
    .master_we_o          (sba_we),
    .master_wdata_o       (sba_wdata),
    .master_be_o          (sba_be),
    .master_gnt_i         (sba_gnt),
    .master_r_valid_i     (sba_rvalid),
    .master_r_err_i       (sba_err),
    .master_r_other_err_i (1'b0),
    .master_r_rdata_i     (sba_rdata),
    // DMI from the TAP
    .dmi_rst_ni           (dmi_rst_n),
    .dmi_req_valid_i      (dmi_req_valid),
    .dmi_req_ready_o      (dmi_req_ready),
    .dmi_req_i            (dmi_req),
    .dmi_resp_valid_o     (dmi_resp_valid),
    .dmi_resp_ready_i     (dmi_resp_ready),
    .dmi_resp_o           (dmi_resp)
  );

  // --------------------------------------------------------------------------
  // Shell status
  //
  // Latch both measurement results so result_i_o/result_q_o stay stable after
  // done, matching the earlier shells' behavior.
  // --------------------------------------------------------------------------
  logic signed [15:0] result_dv_i_q, result_dv_q_q, result_cur_i_q, result_cur_q_q;

  always_ff @(posedge clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      result_dv_i_q  <= 16'd0;
      result_dv_q_q  <= 16'd0;
      result_cur_i_q <= 16'd0;
      result_cur_q_q <= 16'd0;
    end else if (!gpio_start_i) begin
      result_dv_i_q  <= 16'd0;
      result_dv_q_q  <= 16'd0;
      result_cur_i_q <= 16'd0;
      result_cur_q_q <= 16'd0;
    end else if (measurement_done_i) begin
      result_dv_i_q  <= measurement_result_dv_i_i;
      result_dv_q_q  <= measurement_result_dv_q_i;
      result_cur_i_q <= measurement_result_cur_i_i;
      result_cur_q_q <= measurement_result_cur_q_i;
    end
  end

  assign result_dv_i_o  = result_dv_i_q;
  assign result_dv_q_o  = result_dv_q_q;
  assign result_cur_i_o = result_cur_i_q;
  assign result_cur_q_o = result_cur_q_q;
  assign done_o     = fw_done;                       // firmware wrote CTRL.FW_DONE
  assign busy_o     = !core_rst && !fw_done;         // program running

  // Exported for the testbench / a future clock gate; not used in Phase 1.
  wire unused_core_sleep = core_sleep;
  wire unused_trap_seen  = trap_seen;

endmodule
