#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_e2e"
rm -rf "$W"; mkdir -p "$W"
cd "$W"
cp "$BASE/tb/tb_agriasic_rv32i_e2e.sv" .
cp "$BASE/fw/agriasic_fw.hex" .
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/"*.sv .
rm -f agriasic_rv32i_control_shell.sv.orig
echo "=== firmware image: $(wc -l < agriasic_fw.hex) words ==="
echo "=== building simulation ==="
verilator --binary --timing -j 4 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_agriasic_rv32i_e2e \
  -o sim_e2e \
  tb_agriasic_rv32i_e2e.sv \
  agriasic_digital_rv32i_top.sv agriasic_rv32i_control_shell.sv agriasic_digital_top.sv rst_sync.sv \
  measurement_fsm.sv excitation_ctrl.sv sar_controller.sv \
  agriasic_rv32i_core.sv agriasic_imem.sv agriasic_dmem.sv agriasic_rv32i_mmio.sv \
  2>&1 | tail -20
echo "=== running ==="
./obj_dir/sim_e2e 2>&1 | tail -30
