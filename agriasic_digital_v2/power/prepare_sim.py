"""Instrument a build-only copy of the existing functional testbench."""
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
text = (BASE / "tb/tb_agriasic_rv32i_e2e.sv").read_text()
# Retain the original functional checks. Sample activity away from rising edges.
monitor = r'''
  integer power_fd;
  integer epoch_fd;
  integer power_cycle = 0;
  integer power_phase = 0; // 0=before sweep, 1=sweep, 2=post-FW_DONE, 3=start low
  integer last_epoch = -1;
  integer epoch_now;
  integer idle_count = 0;
  longint unsigned counts [0:7][0:11];
  integer row;
  logic [31:0] prev_pc;
  logic [127:0] prev_div;
  logic [127:0] div_state;
  // Ibex: instruction address at the ROM port, and the iterative divider's
  // working registers (RV32MFast multdiv). The Penn core's 8-stage pipelined
  // divider had 1024 state bits; Ibex's has 96 + a 5-bit counter.
  wire [31:0] pc_mon = dut.u_control_shell.instr_addr;
  wire        core_active_mon = !dut.u_control_shell.core_sleep;
  assign div_state = {
    27'd0,
    dut.u_control_shell.u_core.u_ibex_core.ex_block_i.gen_multdiv_fast.multdiv_i.div_counter_q,
    dut.u_control_shell.u_core.u_ibex_core.ex_block_i.gen_multdiv_fast.multdiv_i.op_numerator_q,
    dut.u_control_shell.u_core.u_ibex_core.ex_block_i.gen_multdiv_fast.multdiv_i.op_denominator_q,
    dut.u_control_shell.u_core.u_ibex_core.ex_block_i.gen_multdiv_fast.multdiv_i.op_quotient_q};
  initial begin
    power_fd = $fopen("../results/activity.csv", "w");
    epoch_fd = $fopen("../results/epochs.csv", "w");
    // $time is printed at simulator precision (1 ps in this compilation).
    $fdisplay(epoch_fd, "time_ps,cycle,epoch,divider");
    $dumpfile("activity.vcd");
    $dumpvars(0, dut);
    for (int r=0; r<8; r++)
      for (int c=0; c<12; c++) counts[r][c] = 0;
    prev_pc = 0;
    prev_div = 0;
  end
  always @(negedge clk) begin
    if (rst_n) begin
      power_cycle++;
      if (start_i && power_phase == 0) power_phase = 1;
      if (fw_halted && power_phase == 1) power_phase = 2;
      if (!start_i && power_phase == 2) power_phase = 3;
      epoch_now = (power_phase == 1) ?
        (core_active_mon ? 1 : 2) :
        ((power_phase == 2) ? 3 : ((power_phase == 3) ? 4 : 0));
      if (epoch_now != last_epoch) begin
        $fdisplay(epoch_fd, "%0t,%0d,%0d,%0d", $time, power_cycle, epoch_now, cfg_exc_divider_o);
        last_epoch = epoch_now;
      end
      if (power_phase != 0) begin
        row = (power_phase == 2) ? 6 : ((power_phase == 3) ? 7 :
          ((cfg_exc_divider_o == 10000) ? 4 : ((cfg_exc_divider_o == 100) ? 2 : 0)) +
          (core_active_mon ? 0 : 1));
        counts[row][0]++;
        counts[row][1] += 64'(dut.u_control_shell.instr_req);
        counts[row][2] += 64'(dut.u_control_shell.u_mmio.ram_ce);
        counts[row][3] += 64'(dut.u_control_shell.u_mmio.periph_wr);
        counts[row][4] += 64'(adc_sample_o);
        counts[row][5] += 64'(adc_enable_o);
        counts[row][6] += 64'(dut.u_measurement_top.exc_enable);
        counts[row][7] += 64'(done_o);
        counts[row][8] += 64'($countones(pc_mon ^ prev_pc));
        counts[row][9] += 64'($countones(div_state ^ prev_div));
        counts[row][10] += 64'(core_active_mon);
        counts[row][11] += 64'(dut.u_control_shell.core_rst);
      end
      prev_pc = pc_mon;
      prev_div = div_state;
    end
  end
  task automatic finish_power;
    $fdisplay(power_fd, "row,cycles,imem_ce,ram_ce,periph_writes,adc_samples,adc_on,exc_on,done,pc_bit_toggles,divider_bit_toggles,core_enabled,core_reset");
    for (int r=0; r<8; r++) begin
      $fwrite(power_fd, "%0d", r);
      for (int c=0; c<12; c++) $fwrite(power_fd, ",%0d", counts[r][c]);
      $fwrite(power_fd, "\n");
    end
    $fclose(power_fd);
    $fclose(epoch_fd);
  endtask
'''
text = text.replace("  initial begin\n    errors", monitor + "\n  initial begin\n    errors", 1)
text = text.replace("    $finish;", """    // Observe 4096 cycles after FW_DONE (core parked in wfi).
    repeat (4096) @(posedge clk);
    @(negedge clk);
    start_i = 1'b0;
    repeat (4096) @(posedge clk);
    #1;
    finish_power();
    $finish;""", 1)
(BASE / "power/build/tb_power_generated.sv").write_text(text)
(BASE / "power/results").mkdir(exist_ok=True)
