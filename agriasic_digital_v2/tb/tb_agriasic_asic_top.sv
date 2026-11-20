// -----------------------------------------------------------------------------
// Chip-top testbench: firmware, digital and the analog front-end macro all in
// the loop, driving a tetrapolar electrode load that responds to the chip's
// OWN excitation output.
//
// WHAT THIS CHECKS
//   * the chip boots, sequences measurements and converts a real analog
//     response;
//   * every SAR result equals the code the AFE model's comparator input
//     implies (the comparator timing works with sar_controller);
//   * the held voltage and current survive until each is converted;
//   * no conversion lands on code 0 or 255 (the load is sized to stay in
//     range, so a clipped code means something upstream is wrong);
//   * END TO END: the impedance the chip reports, dV / I from its own I/Q
//     accumulators, matches the impedance of the inner soil segment, at the
//     first PointsChecked sweep points.
//
// The impedance check folds in the AFE model's own fitted amplifier response
// (one voltage-path pole, two equal current-path poles) because the real
// system de-embeds exactly that off die. What remains is quantisation,
// sampling of the 16-step excitation and the model's arithmetic, so the
// tolerance below is for gross breakage, not a precision claim. The model is
// the 2026-11-20 analog handoff: see rtl/analog/README.md for what it does
// and does not represent.
//
// tb_agriasic_rv32i_e2e.sv remains the bench that checks exact accumulator
// arithmetic, using a fixed-code ADC model.
//
// Needs --timing: the AFE boundary has no clock.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_agriasic_asic_top;
  import agriasic_afe_pkg::*;

  localparam real ClkNs     = 6.25;    // 160 MHz
  localparam int  TimeoutUs = 500;
  // Sweep points checked: 10 MHz, 1 MHz and 312.5 kHz. Each lower point
  // costs roughly 3x the simulated time of the one above it.
  localparam int  PointsChecked = 3;
  localparam real ZMagTol       = 0.10;  // fraction
  localparam real ZPhaseTolDeg  = 10.0;

  logic clk = 1'b0;
  logic rst_n;
  logic start_i;

  always #(ClkNs / 2.0) clk = ~clk;

  // ---------------------------------------------------------------------------
  // Electrode load, wired the way the tetrapolar probe is:
  //
  //   E1 --Rc-- [seg] --E2-- [seg] --E3-- [seg] --Rc-- E4 (TIA input, at VCM)
  //
  // Each soil segment is SoilSegOhm in parallel with SoilSegF; the contacts
  // are resistive. One current flows through the whole chain, and dV is taken
  // across the middle segment only, so the impedance the chip should report
  // is exactly one segment's, whatever the contacts do -- which is the point
  // of measuring with four electrodes.
  //
  // Sized for the AFE model's full scales at the firmware's settings (TIA
  // code 001, full excitation amplitude): the current peaks near 210 uA at
  // 10 MHz against +/-305 uA full scale, and dV at the converter stays within
  // about 60 codes of mid-scale. Illustrative values, not a soil
  // characterisation.
  // ---------------------------------------------------------------------------
  localparam real ContactOhm = 1.0e3;
  localparam real SoilSegOhm = 330.0;
  localparam real SoilSegF   = 150.0e-12;

  real e1_drive;                        // from the chip
  real e2_sense, e3_sense, e4_iin;
  real vin_t = 0.90;

  // All three segments carry the same current, so they share one state: the
  // voltage across each. With v_d the drive about VCM,
  //   i = (v_d - 3 v_seg) / (2 Rc),   C dv_seg/dt = i - v_seg / R,
  // stepped exactly for an input held over the step.
  real v_seg = 0.0;
  real v_d, v_inf;
  localparam real SegRate =
      (3.0 / (2.0 * ContactOhm) + 1.0 / SoilSegOhm) / SoilSegF;   // 1/s

  initial begin
    e2_sense = VCM_NOM_V;
    e3_sense = VCM_NOM_V;
    e4_iin   = 0.0;
  end

  always begin
    #(ANALOG_STEP_NS);
    v_d   = e1_drive - VCM_NOM_V;
    v_inf = (v_d / (2.0 * ContactOhm)) / (3.0 / (2.0 * ContactOhm) + 1.0 / SoilSegOhm);
    v_seg = v_inf + (v_seg - v_inf) * $exp(-SegRate * ANALOG_STEP_NS * 1.0e-9);
    e4_iin   = (v_d - 3.0 * v_seg) / (2.0 * ContactOhm);   // amperes, into E4
    e2_sense = e1_drive - e4_iin * ContactOhm - v_seg;
    e3_sense = e2_sense - v_seg;
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
  // Converter checks, against the AFE model's own sampler
  // (dut.u_afe.chain.sense): what it held at each strobe, what it handed the
  // comparator at each capture, and what the SAR returned.
  // ---------------------------------------------------------------------------
  int  samples_taken = 0, captures = 0, conversions = 0;
  int  hold_lost = 0, code_mismatch = 0, clipped = 0;
  real strobe_v, strobe_i, cap_v;
  logic [1:0] cap_sel;

  always @(posedge dut.u_afe.chain.sense.holding) samples_taken++;

  always @(posedge dut.afe_sample) begin
    #0.001;                             // after the model's capture, same step
    strobe_v = dut.u_afe.chain.sense.held_v;
    strobe_i = dut.u_afe.chain.sense.held_i;
  end

  always @(posedge dut.u_afe.chain.sense.armed) begin
    captures++;
    cap_v   = dut.u_afe.chain.sense.adc_v;
    cap_sel = dut.u_afe.chain.sense.selected;
    if ((cap_sel == 2'd0 && cap_v != strobe_v) || (cap_sel == 2'd1 && cap_v != strobe_i)) begin
      hold_lost++;
      if (hold_lost <= 3)
        $display("HOLD_LOST: channel %0d captured %0.4f V, held %0.4f V at the strobe",
                 cap_sel, cap_v, (cap_sel == 2'd0) ? strobe_v : strobe_i);
    end
  end

  always @(posedge clk) begin
    if (dut.u_digital.u_measurement_top.u_sar_controller.sample_done_o) begin
      int  ideal, got;
      real x;
      conversions++;
      // Comparator: 1 = input >= VREFL + code * LSB, so the binary search
      // converges on floor((v - VREFL) / LSB), clamped to the code range.
      x     = (cap_v - VREFL_NOM_V) / ADC_LSB_V;
      ideal = (x < 0.0) ? 0 : ((x >= 255.0) ? 255 : int'($floor(x)));
      got   = int'(dut.u_digital.u_measurement_top.u_sar_controller.code_o);
      if (got == 0 || got == 255) clipped++;
      if (got != ideal) begin
        code_mismatch++;
        if (code_mismatch <= 5)
          $display("CODE_MISMATCH: channel %0d input %0.4f V -> expected %0d, SAR %0d",
                   cap_sel, cap_v, ideal, got);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Acquisition window (GAP-A6, closed): hold release -> next strobe, and the
  // strobe spacing. Reported for comparison with the analog S/H
  // characterisation; this AFE model tracks ideally, so it cannot itself say
  // whether the window is long enough (GAP-A2).
  // ---------------------------------------------------------------------------
  realtime t_strobe, t_release, t_prev_strobe;
  real     worst_pair_ns = 0.0;
  real     worst_reacq_ns = 1.0e9;
  real     shortest_strobe_gap_ns = 1.0e9;
  int      enable_falls = 0;

  initial begin
    t_strobe      = 0.0;
    t_prev_strobe = 0.0;
    t_release     = 0.0;
  end

  always @(negedge dut.u_afe.chain.sense.holding) t_release = $realtime;

  always @(posedge dut.afe_sample) begin
    if (t_release > 0.0 && ($realtime - t_release) < worst_reacq_ns)
      worst_reacq_ns = $realtime - t_release;
    if (t_prev_strobe > 0.0 && ($realtime - t_prev_strobe) < shortest_strobe_gap_ns)
      shortest_strobe_gap_ns = $realtime - t_prev_strobe;
    t_prev_strobe = $realtime;
    t_strobe      = $realtime;
    enable_falls  = 0;
  end

  always @(negedge dut.afe_adc_enable) begin
    if (t_strobe > 0.0) begin
      enable_falls++;
      // Second falling edge = both conversions of the pair are done.
      if (enable_falls == 2 && ($realtime - t_strobe) > worst_pair_ns)
        worst_pair_ns = $realtime - t_strobe;
    end
  end

  // ---------------------------------------------------------------------------
  // End-to-end impedance
  //
  // Per pair the accumulators hold I = D(0) - D(180) and Q = D(90) - D(270),
  // so a channel's phasor is proportional to I - jQ. The converter scale and
  // pair count cancel between the two channels, leaving
  //   Z = (dv_i - j dv_q) / (cur_i - j cur_q) * R_T / A_V,
  // with A_V and R_T the AFE model's fitted gains. Both paths are
  // non-inverting in this model. Its fitted poles make the reading
  //   Z_seg(f) * H_v(f) / H_i(f),  H_v = 1/(1 + jwTv),  H_i = 1/(1 + jwTi)^2,
  // which is what the expected value below includes.
  // ---------------------------------------------------------------------------
  localparam real Pi = 3.14159265358979;

  function automatic real phase_deg(input real re, input real im);
    return $atan2(im, re) * 180.0 / Pi;
  endfunction

  int z_fail = 0;

  task automatic check_impedance(input int n_div);
    real f, w, wrc, zr, zi, a, b, er, ei, t, mr, mi, nr, ni, d, rt, tt, av, tv;
    real mag_err, ph_err;
    // Current-path gain and pole for the TIA code the firmware selected.
    case (dut.afe_tia_rf)
      3'b001:  begin rt = dut.u_afe.chain.TIA_G0; tt = dut.u_afe.chain.TIA_T0; end
      3'b010:  begin rt = dut.u_afe.chain.TIA_G1; tt = dut.u_afe.chain.TIA_T1; end
      3'b100:  begin rt = dut.u_afe.chain.TIA_G2; tt = dut.u_afe.chain.TIA_T2; end
      default: begin rt = dut.u_afe.chain.TIA_G3; tt = dut.u_afe.chain.TIA_T3; end
    endcase
    av = dut.u_afe.chain.PGA_GAIN;
    tv = dut.u_afe.chain.PGA_TAU_NS;

    f   = 1.0e9 / (ClkNs * 16.0 * real'(n_div));
    w   = 2.0 * Pi * f;
    // Z_seg = R / (1 + jwRC)
    wrc = w * SoilSegOhm * SoilSegF;
    zr  = SoilSegOhm / (1.0 + wrc * wrc);
    zi  = -SoilSegOhm * wrc / (1.0 + wrc * wrc);
    // times (1 + jwTi)^2 / (1 + jwTv)
    t   = w * tt * 1.0e-9;
    a   = 1.0 - t * t;  b = 2.0 * t;                  // (1 + jt)^2
    er  = zr * a - zi * b;  ei = zr * b + zi * a;
    t   = w * tv * 1.0e-9;
    d   = 1.0 + t * t;
    zr  = (er + ei * t) / d;  zi = (ei - er * t) / d;  // / (1 + jt)

    // Measured: (dv_i - j dv_q) / (cur_i - j cur_q) * R_T / A_V
    nr = real'(res_dv_i);   ni = -real'(res_dv_q);
    d  = real'(res_cur_i) * real'(res_cur_i) + real'(res_cur_q) * real'(res_cur_q);
    if (d == 0.0) begin
      z_fail++;
      $display("FAIL: N=%0d current accumulators are zero", n_div);
      return;
    end
    mr = (nr * real'(res_cur_i) + ni * (-real'(res_cur_q))) / d;
    mi = (ni * real'(res_cur_i) - nr * (-real'(res_cur_q))) / d;
    mr = mr * rt / av;  mi = mi * rt / av;

    mag_err = $sqrt(mr * mr + mi * mi) / $sqrt(zr * zr + zi * zi) - 1.0;
    ph_err  = phase_deg(mr, mi) - phase_deg(zr, zi);
    if (ph_err > 180.0)  ph_err -= 360.0;
    if (ph_err < -180.0) ph_err += 360.0;

    $display("  N=%0d, %0.1f kHz: |Z| %0.1f ohm (expected %0.1f, error %0.1f %%), phase %0.2f deg (expected %0.2f, error %0.2f deg)",
             n_div, f / 1.0e3, $sqrt(mr * mr + mi * mi), $sqrt(zr * zr + zi * zi),
             100.0 * mag_err, phase_deg(mr, mi), phase_deg(zr, zi), ph_err);
    if (mag_err > ZMagTol || mag_err < -ZMagTol
        || ph_err > ZPhaseTolDeg || ph_err < -ZPhaseTolDeg)
      z_fail++;
  endtask

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

  int measurements = 0;
  int points_seen  = 0;
  int last_div     = -1;

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

    // Every measurement of the first PointsChecked sweep points, checked as
    // it completes. The lower points are left to tb_agriasic_rv32i_e2e.sv:
    // the 1 kHz point alone settles for 320,000 cycles.
    $display("--- end-to-end impedance, per measurement ---");
    fork
      begin
        forever begin
          @(posedge done_o);
          @(posedge clk);                   // shadow registers copied
          @(posedge clk);                   // (no repeat: Verilator LIFETIME inside fork)
          if (int'(cfg_div) != last_div) begin
            if (points_seen == PointsChecked) break;
            points_seen++;
            last_div = int'(cfg_div);
          end
          measurements++;
          check_impedance(int'(cfg_div));
        end
      end
      begin
        #(TimeoutUs * 1000.0);
        errs++;
        $display("FAIL: timed out after %0d us", TimeoutUs);
      end
    join_any
    disable fork;

    $display("--- converter ---");
    $display("  strobes %0d, captures %0d, conversions %0d", samples_taken, captures, conversions);
    $display("--- acquisition window (GAP-A6) ---");
    $display("  longest conversion pair : %0.0f ns", worst_pair_ns);
    $display("  shortest strobe gap     : %0.0f ns", shortest_strobe_gap_ns);
    $display("  hold release -> strobe  : %0.0f ns (model S/H tracks ideally; see GAP-A2)",
             worst_reacq_ns);

    expect_true(measurements >= PointsChecked, $sformatf("%0d measurements completed over %0d sweep points",
                                                         measurements, points_seen));
    expect_true(conversions > 0 && code_mismatch == 0,
                $sformatf("every SAR code equals the AFE model's ideal code (%0d mismatches)", code_mismatch));
    expect_true(hold_lost == 0,
                $sformatf("held V and I survive until their conversions (%0d lost)", hold_lost));
    expect_true(clipped == 0,
                $sformatf("no conversion at code 0 or 255 (%0d)", clipped));
    expect_true(measurements > 0 && z_fail == 0,
                $sformatf("reported impedance within %0.0f %% and %0.0f deg of the soil segment (%0d outside)",
                          100.0 * ZMagTol, ZPhaseTolDeg, z_fail));

    if (errs == 0) $display("TB_ASIC_TOP: PASS");
    else           $display("TB_ASIC_TOP: FAIL (%0d)", errs);
    $finish;
  end

endmodule
