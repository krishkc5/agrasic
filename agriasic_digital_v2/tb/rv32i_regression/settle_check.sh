#!/bin/bash
# Regression for the Rev 4.3 settle-path fixes (defects 1 and 2).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_settle"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

cp "$BASE/tb/tb_settle_timing.sv" .
cp "$BASE/rtl/agriasic_digital_top.sv" .
cp "$BASE/rtl/ctrl/measurement_fsm.sv" "$BASE/rtl/ctrl/excitation_ctrl.sv" \
   "$BASE/rtl/ctrl/sar_controller.sv" .

verilator --binary --timing -j 4 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_settle_timing -o sim_settle \
  tb_settle_timing.sv agriasic_digital_top.sv measurement_fsm.sv \
  excitation_ctrl.sv sar_controller.sv > build.log 2>&1 \
  || { echo "BUILD FAILED"; grep -E "^%Error|^%Warning" build.log | head -10; exit 1; }

./obj_dir/sim_settle 2>&1 | grep -E "^\[TB\]|SETTLE_" | head -12
