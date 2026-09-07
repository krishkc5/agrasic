#!/bin/bash
# Settle x conv grid sweep (Rev 4.3 Phase 8, closes verification item V-1).
# See tb_settle_conv_sweep.sv's header for the practical-grid-vs-exhaustive
# reasoning.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_settle_conv_sweep"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
cp "$BASE/tb/tb_settle_conv_sweep.sv" .
cp "$BASE/rtl/agriasic_digital_top.sv" .
cp "$BASE/rtl/ctrl/measurement_fsm.sv" "$BASE/rtl/ctrl/excitation_ctrl.sv" "$BASE/rtl/ctrl/sar_controller.sv" .
verilator --binary --timing -j 4 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_settle_conv_sweep -o sim_settle_conv_sweep \
  tb_settle_conv_sweep.sv agriasic_digital_top.sv measurement_fsm.sv \
  excitation_ctrl.sv sar_controller.sv > build.log 2>&1 \
  || { echo "BUILD FAILED"; tail -20 build.log; exit 1; }
./obj_dir/sim_settle_conv_sweep 2>&1 | grep -E "^\[TB\]|SETTLE_CONV_" | head -10
