#!/bin/bash
# Unit regression for the Rev 4.3 sar_controller bit-trial rewrite.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_sar_bit_trial"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

cp "$BASE/tb/tb_sar_bit_trial.sv" .
cp "$BASE/rtl/ctrl/sar_controller.sv" .

verilator --binary --timing -j 4 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_sar_bit_trial -o sim_sar \
  tb_sar_bit_trial.sv sar_controller.sv > build.log 2>&1 \
  || { echo "BUILD FAILED"; grep -E "^%Error|^%Warning" build.log | head -10; exit 1; }

./obj_dir/sim_sar 2>&1 | grep -E "^\[TB\]|SAR_|ASSERT_FAIL" | head -20
