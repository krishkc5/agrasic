#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_e2e"; mkdir -p "$W"; cd "$W"
# Re-copy ALL sources, not just the testbench, so RTL edits are picked up.
cp "$BASE/tb/tb_diag.sv" .
cp "$BASE/rtl/"*.sv . 2>/dev/null || true
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/"*.sv .
cp "$BASE/fw/agriasic_fw.hex" .
rm -f agriasic_rv32i_control_shell.sv.orig sar_controller.sv.orig
verilator --binary --timing -j 4 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_diag -o sim_diag \
  tb_diag.sv agriasic_digital_rv32i_top.sv agriasic_rv32i_control_shell.sv agriasic_digital_top.sv rst_sync.sv \
  measurement_fsm.sv excitation_ctrl.sv sar_controller.sv \
  agriasic_rv32i_core.sv agriasic_imem.sv agriasic_dmem.sv agriasic_rv32i_mmio.sv \
  > /tmp/diag_build.log 2>&1 || { tail -20 /tmp/diag_build.log; exit 1; }
./obj_dir/sim_diag 2>&1 | head -60
