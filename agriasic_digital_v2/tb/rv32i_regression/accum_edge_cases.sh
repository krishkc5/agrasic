#!/bin/bash
# Accumulator edge-case regression (Rev 4.3 Phase 8, closes verification
# item V-2). See tb_accum_edge_cases.sv's header for what this actually
# checks and why the original D-3 rounding defect class no longer applies.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/waves.sh"
W="$HOME/agriasic_accum_edge"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
wave_setup tb_accum_edge_cases accum_edge_cases
cp "$BASE/tb/tb_accum_edge_cases.sv" .
cp "$BASE/rtl/agriasic_digital_top.sv" .
cp "$BASE/rtl/ctrl/measurement_fsm.sv" "$BASE/rtl/ctrl/excitation_ctrl.sv" "$BASE/rtl/ctrl/sar_controller.sv" .
verilator $WAVE_ARGS --binary --timing -j 4 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_accum_edge_cases -o sim_accum_edge \
  tb_accum_edge_cases.sv agriasic_digital_top.sv measurement_fsm.sv \
  excitation_ctrl.sv sar_controller.sv > build.log 2>&1 \
  || { echo "BUILD FAILED"; tail -20 build.log; exit 1; }
./obj_dir/sim_accum_edge 2>&1 | grep -E "^\[TB\]|ACCUM_EDGE_" | head -10
wave_report
