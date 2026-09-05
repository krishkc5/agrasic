#!/bin/bash
# Regression for the Rev 4.3 Phase 4 free-running excitation generator.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_exc_drive"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

cp "$BASE/tb/tb_excitation_drive.sv" .
cp "$BASE/rtl/ctrl/excitation_ctrl.sv" .

verilator --binary --timing -j 4 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_excitation_drive -o sim_exc \
  tb_excitation_drive.sv excitation_ctrl.sv > build.log 2>&1 \
  || { echo "BUILD FAILED"; grep -E "^%Error|^%Warning" build.log | head -10; exit 1; }

./obj_dir/sim_exc 2>&1 | grep -E "^\[TB\]|EXCITATION_|ASSERT_FAIL|FREQ_FAIL|PERIOD_FAIL|PHASE_MAP_FAIL|IDLE_FAIL" | head -20
