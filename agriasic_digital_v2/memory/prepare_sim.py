"""Add read-only memory monitors to a generated copy of the existing e2e TB."""
from pathlib import Path
BASE = Path(__file__).resolve().parents[1]
text = (BASE / "tb/tb_agriasic_rv32i_e2e.sv").read_text()
monitor = r'''
  // Read-only address monitors on the Ibex core's memory ports.
  //   fetch : instr_req/instr_addr as sampled by the ROM
  //   load/store : data_req/data_we/data_be/data_addr as sampled by the bridge
  //   retire : instruction leaving the writeback stage (pc_wb)
  //   sp : x2 from the FF register file (simulation build)
  integer mem_fd;
  integer mem_cycle = 0;
  logic mem_after_halt = 0;
  logic [31:0] prev_sp = 0;
  wire [31:0] mem_sp = dut.u_control_shell.u_core.gen_regfile_ff.register_file_i.g_plain_rf.rf_reg[2];
  initial begin
    mem_fd = $fopen("accesses.csv", "w");
    $fdisplay(mem_fd, "cycle,after_ecall,kind,address,byte_mask");
  end
  // Pre-NBA values are the requests actually sampled by the memory at this edge.
  always @(posedge clk) begin
    mem_cycle++;
    if (rst_n && start_i && dut.u_control_shell.core_rst_n) begin
      if (fw_halted) mem_after_halt = 1;
      if (dut.u_control_shell.u_core.u_ibex_core.instr_done_wb) begin
        $fdisplay(mem_fd, "%0d,%0d,retire,%08x,f", mem_cycle, mem_after_halt,
                  dut.u_control_shell.u_core.u_ibex_core.pc_wb);
      end
      // Phase 2 flat map: IMEM 0x0000_0000-0x0FFF, DMEM 0x0001_0000-0x0001_07FF,
      // DM 0x1A11_0000-0x0FFF (debug ROM on the instruction side; never touched
      // in this run because no debugger is attached), MMIO 0x8000_0000-0x1F.
      if (dut.u_control_shell.instr_req && dut.u_control_shell.instr_gnt) begin
        $fdisplay(mem_fd, "%0d,%0d,fetch,%08x,f", mem_cycle, mem_after_halt, dut.u_control_shell.instr_addr);
        if (dut.u_control_shell.instr_addr > 32'h00000ffc &&
            !(dut.u_control_shell.instr_addr >= 32'h1A110000 && dut.u_control_shell.instr_addr <= 32'h1A110ffc))
          $fatal(1, "fetch outside IMEM / debug ROM");
      end
      if (dut.u_control_shell.data_req && dut.u_control_shell.data_gnt) begin
        $fdisplay(mem_fd, "%0d,%0d,%0s,%08x,%01x", mem_cycle, mem_after_halt,
          dut.u_control_shell.data_we ? "store" : "load",
          dut.u_control_shell.data_addr,
          dut.u_control_shell.data_we ? dut.u_control_shell.data_be : 4'hf);
        if (dut.u_control_shell.data_addr[31]) begin
          if (dut.u_control_shell.data_addr > 32'h8000003c)
            $fatal(1, "MMIO request outside intended 64-byte window");
        end else if (dut.u_control_shell.data_addr < 32'h00010000 ||
                     dut.u_control_shell.data_addr > 32'h000107fc)
          $fatal(1, "data request outside implemented 2 KiB DMEM at 0x00010000");
      end
      if (mem_sp != prev_sp) begin
        $fdisplay(mem_fd, "%0d,%0d,sp,%08x,0", mem_cycle, mem_after_halt, mem_sp);
        prev_sp = mem_sp;
      end
    end
  end
'''
text = text.replace("  initial begin\n    errors", monitor + "\n  initial begin\n    errors", 1)
text = text.replace("    $finish;", "    repeat (32) @(posedge clk);\n    #1;\n    $fclose(mem_fd);\n    $finish;", 1)
build = BASE / "memory/build"
build.mkdir(parents=True, exist_ok=True)
(build / "tb_memory_generated.sv").write_text(text)
