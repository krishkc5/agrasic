// -----------------------------------------------------------------------------
// Chip-top testbench: firmware, digital and the analog front-end macro all in
// the loop. The electrodes are driven by a soil model that responds to the
// chip's OWN excitation output, so for the first time the conversion result
// depends on analog behaviour rather than on a lookup keyed to FSM state.
//
// WHAT THIS CHECKS, AND WHAT IT DELIBERATELY DOES NOT.
// It checks that the chip boots, sequences measurements, and converts a real
// analog response without tripping any of the macro's integration checks,
// and it reports the sampling accuracy in LSBs.
//
// It does NOT check exact I/Q values. Those would require reimplementing the
// demodulation here, and the numbers would only be as trustworthy as the
// placeholder analog constants they came from (see
// docs/analog_integration_gaps.md). tb_agriasic_rv32i_e2e.sv remains the
// bench that checks exact accumulator arithmetic, using a fixed-code ADC
// model -- the two are complementary and neither replaces the other.
//
// Needs --timing: the AFE boundary has no clock.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_agriasic_asic_top;
  import agriasic_afe_pkg::*;

  localparam real ClkNs = 6.25;    // 160 MHz
  localparam int  TimeoutUs = 500;

  logic clk = 1'b0;
  logic rst_n;
  logic start_i;

  always #(ClkNs / 2.0) clk = ~clk;

  // ---------------------------------------------------------------------------
  // Soil model. A parallel RC between the drive electrode and ground: the
  // voltage sensed across the inner electrode pair is in phase with the
  // drive, the return current leads it. That phase split is the whole point
  // of the tetrapolar measurement, so a purely resistive model would not
  // exercise the I/Q accumulation meaningfully.
  //
  // These values are illustrative. Real soil response is outside anything
  // this tree models.
  // ---------------------------------------------------------------------------
  localparam real SoilROhm   = 50.0e3;
  localparam real SoilCFarad = 2.0e-9;
  localparam real SenseFrac  = 0.05;    // dV across the inner pair / drive

  real e1_drive;                        // from the chip
  real e2_sense, e3_sense, e4_iin;
  real vin_t = 0.90;

  real v_drive_q, v_drive_prev, i_cap, i_res;

  initial begin
    v_drive_prev = VCM_NOM_V;
    e2_sense     = VCM_NOM_V;
    e3_sense     = VCM_NOM_V;
    e4_iin       = 0.0;
  end

  always begin
    #(ANALOG_STEP_NS);
    v_drive_q = e1_drive - VCM_NOM_V;             // excitation about VCM

    // i = v/R + C dv/dt, differentiated on the model timestep (ns -> s).
    i_res  = v_drive_q / SoilROhm;
    i_cap  = SoilCFarad * (v_drive_q - (v_drive_prev - VCM_NOM_V))
           / (ANALOG_STEP_NS * 1.0e-9);
    e4_iin = i_res + i_cap;

    // Differential sense across the inner electrode pair, in phase.
    e2_sense = VCM_NOM_V + 0.5 * SenseFrac * v_drive_q;
    e3_sense = VCM_NOM_V - 0.5 * SenseFrac * v_drive_q;

    v_drive_prev = e1_drive;
  end

  // ---------------------------------------------------------------------------
  // Device
  // ---------------------------------------------------------------------------
  logic        busy_o, done_o;
  logic signed [15:0] res_dv_i, res_dv_q, res_cur_i, res_cur_q;
  logic [3:0]  cfg_pair_log2;
  logic [7:0]  cfg_settle, cfg_conv, cfg_mux_settle;
  logic [13:0] cfg_div;
  logic [1:0]  cfg_amp;
  logic        jtag_tdo, flash_sck, flash_cs_n, flash_mosi, boot_fail;
  logic        spi_miso, spi_miso_oe;

  agriasic_asic_top #(
    .BOOT_DELAY_CYCLES (64),
    .IMEM_PRELOADED    (1'b1)     // IMEM comes from $readmemh; boot FSM skips
  ) dut (
    .clk (clk), .rst_n (rst_n), .gpio_start_i (start_i),

    .gpio_jtag_tck_i (1'b0), .gpio_jtag_tms_i (1'b0),
    .gpio_jtag_trst_ni (1'b1), .gpio_jtag_tdi_i (1'b0),
    .gpio_jtag_tdo_o (jtag_tdo),

    .gpio_boot_sel_i (1'b0),
    .gpio_flash_sck_o (flash_sck), .gpio_flash_cs_n_o (flash_cs_n),
    .gpio_flash_mosi_o (flash_mosi), .gpio_flash_miso_i (1'b1),
    .gpio_boot_fail_o (boot_fail),

    .gpio_spi_sclk_i (1'b0), .gpio_spi_cs_n_i (1'b1), .gpio_spi_mosi_i (1'b0),
    .gpio_spi_miso_o (spi_miso), .gpio_spi_miso_oe_o (spi_miso_oe),

    .afe_e1_drive_o (e1_drive),
    .afe_e2_sense_i (e2_sense),
    .afe_e3_sense_i (e3_sense),
    .afe_e4_iin_i   (e4_iin),
    .afe_vin_t_i    (vin_t),
    .afe_vdda_i     (VDDA_NOM_V),
    .afe_vssa_i     (VSSA_NOM_V),
    .afe_vrefh_i    (VREFH_NOM_V),
    .afe_vrefl_i    (VREFL_NOM_V),
    .afe_vcm_i      (VCM_NOM_V),
    .afe_ibias_i    (IBIAS_NOM_A),

    .dbg_busy_o (busy_o), .dbg_done_o (done_o),
    .dbg_result_dv_i_o (res_dv_i), .dbg_result_dv_q_o (res_dv_q),
    .dbg_result_cur_i_o (res_cur_i), .dbg_result_cur_q_o (res_cur_q),
    .dbg_cfg_pair_log2_o (cfg_pair_log2),
    .dbg_cfg_settle_cycles_o (cfg_settle),
    .dbg_cfg_exc_divider_o (cfg_div),
    .dbg_cfg_conv_cycles_o (cfg_conv),
    .dbg_cfg_mux_settle_o (cfg_mux_settle),
    .dbg_cfg_amplitude_o (cfg_amp)
  );

  // ---------------------------------------------------------------------------
  // Sampling accuracy, accumulated across the run. The macro reports each
  // freeze; this keeps the worst case so the run ends with one number.
  // ---------------------------------------------------------------------------
  real worst_acq_lsb = 0.0;
  int  samples_taken = 0;

  function automatic real abs_lsb(input real err_v);
    return (err_v < 0.0) ? (-err_v / ADC_LSB_V) : (err_v / ADC_LSB_V);
  endfunction

  always @(posedge dut.u_afe.sh_dv_holding) begin
    samples_taken++;
    if (abs_lsb(dut.u_afe.acq_err_dv) > worst_acq_lsb)
      worst_acq_lsb = abs_lsb(dut.u_afe.acq_err_dv);
    if (abs_lsb(dut.u_afe.acq_err_cur) > worst_acq_lsb)
      worst_acq_lsb = abs_lsb(dut.u_afe.acq_err_cur);
  end

  // ---------------------------------------------------------------------------
  // GAP-A6, second half: how long must the self-timed hold actually last?
  // There is no release signal on the boundary, so the analog needs a fixed
  // timer that outlasts a whole conversion PAIR -- strobe, dV conversion,
  // current conversion. Measured here rather than estimated, because the
  // window depends on the mux_settle and conv_cycles the firmware programs.
  // ---------------------------------------------------------------------------
  realtime t_strobe;
  real     worst_pair_ns = 0.0;
  int      enable_falls  = 0;

  real     shortest_strobe_gap_ns = 1.0e9;
  realtime t_prev_strobe;
  logic    done_seen;

  initial begin
    t_strobe      = 0.0;
    t_prev_strobe = 0.0;
    done_seen     = 1'b0;
  end

  always @(posedge done_o) done_seen = 1'b1;

  always @(posedge dut.afe_sample) begin
    if (t_prev_strobe > 0.0
        && ($realtime - t_prev_strobe) < shortest_strobe_gap_ns)
      shortest_strobe_gap_ns = $realtime - t_prev_strobe;
    t_prev_strobe = $realtime;
    t_strobe      = $realtime;
    enable_falls  = 0;
  end

  always @(negedge dut.afe_adc_enable) begin
    if (t_strobe > 0.0) begin
      enable_falls++;
      // Second falling edge = both conversions of the pair are done.
      if (enable_falls == 2) begin
        if (($realtime - t_strobe) > worst_pair_ns)
          worst_pair_ns = $realtime - t_strobe;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  int errs = 0;

  task automatic expect_true(input bit c, input string what);
    if (!c) begin
      errs++;
      $display("FAIL: %s", what);
    end else begin
      $display("ok  : %s", what);
    end
  endtask

  initial begin
    // Reset sequence copied from tb_agriasic_rv32i_e2e.sv, and it is NOT
    // optional. Ibex gates its core clock while idle, so its async-reset
    // flops only see reset through a real NEGEDGE on rst_ni, and under the
    // simulator's 2-state initialisation a reset that starts asserted never
    // produces one. The core's reset is rst_n_sync && start_i, so both must
    // be driven high first, then reset asserted, then released.
    rst_n   = 1'b1;
    start_i = 1'b1;
    repeat (12) @(posedge clk);
    rst_n   = 1'b0;
    start_i = 1'b0;
    repeat (10) @(posedge clk);
    rst_n   = 1'b1;
    repeat (5) @(posedge clk);

    $display("--- excitation check ---");
    expect_true(e1_drive > 0.1 && e1_drive < 1.7, "E1 drive inside the rails");

    // start_i is a LEVEL, not a pulse: it gates the core's reset.
    $display("[TB] releasing start, firmware begins");
    start_i = 1'b1;

    // Scoped to the FIRST measurement, not the whole sweep. The firmware's
    // 3-point sweep runs up to 8,000,000 cycles because the 1 kHz point's
    // settle alone is 320,000 -- 50 ms of wall-clock analog stepping, which
    // this bench has no reason to pay. tb_agriasic_rv32i_e2e.sv covers the
    // full sweep with a digital ADC model; what is being proved here is that
    // a real analog response converts correctly at all.
    fork
      begin
        wait (done_o === 1'b1);
        $display("[TB] first measurement completed");
      end
      begin
        #(TimeoutUs * 1000.0);
        errs++;
        $display("FAIL: timed out after %0d us waiting for the first measurement",
                 TimeoutUs);
      end
    join_any
    disable fork;

    repeat (10) @(posedge clk);

    $display("--- results (first measurement) ---");
    $display("  dv_i  = %0d", res_dv_i);
    $display("  dv_q  = %0d", res_dv_q);
    $display("  cur_i = %0d", res_cur_i);
    $display("  cur_q = %0d", res_cur_q);
    $display("--- sampling ---");
    $display("  samples taken      : %0d", samples_taken);
    $display("  worst acquisition  : %0.2f LSB", worst_acq_lsb);
    $display("--- GAP-A6: self-timed hold window ---");
    $display("  longest conversion pair : %0.0f ns   (hold must EXCEED this)",
             worst_pair_ns);
    $display("  shortest strobe gap     : %0.0f ns   (hold must be UNDER this)",
             shortest_strobe_gap_ns);
    $display("  re-acquisition available: %0.0f ns   (gap minus pair)",
             shortest_strobe_gap_ns - worst_pair_ns);
    $display("  re-acquisition NEEDED   : %0.0f ns   (6.24 x SH_TAU_NS, half-LSB)",
             6.24 * SH_TAU_NS);
    if ((shortest_strobe_gap_ns - worst_pair_ns) < (6.24 * SH_TAU_NS))
      $display("  -> INFEASIBLE: the conversion pair plus re-acquisition does not");
    else
      $display("  -> feasible, but the fixed analog timer must fit between them;");
    $display("     fit inside the strobe period. See GAP-A6.");

    // The sampling slide's own criterion is half an LSB, but that figure is
    // for a DC step. The first sweep point drives exc_divider = 1, i.e. an
    // excitation around 10 MHz, where the 7.2 ns S/H time constant is no
    // longer negligible against the signal's slew rate and the tracking lag
    // becomes the dominant error. Reported either way; the assertion uses a
    // looser bound so it catches gross breakage rather than failing on a
    // real and expected frequency effect. See GAP-A2.
    if (samples_taken > 0) begin
      $display("  half-LSB criterion : %s",
               (worst_acq_lsb < 0.5) ? "met" : "NOT met (tracking lag, see GAP-A2)");
    end

    expect_true(done_seen,         "measurement completed");
    expect_true(samples_taken > 0, "the AFE was strobed at least once");
    // Guarded: with no samples this would otherwise pass vacuously.
    expect_true(samples_taken > 0 && worst_acq_lsb < 2.0,
                "acquisition error under 2 LSB");
    // One accumulation pair is four phase points, so four strobes. That is a
    // real liveness check on the analog path. The accumulator VALUES are
    // printed but not asserted -- see this file's header for why exact I/Q
    // is out of scope here.
    expect_true(samples_taken >= 4, "at least one full accumulation pair sampled");

    if (errs == 0) $display("TB_ASIC_TOP: PASS");
    else           $display("TB_ASIC_TOP: FAIL (%0d)", errs);
    $finish;
  end

endmodule
