#!/bin/bash
# Regression for the Rev 4.3 Phase 2.1 reset synchronizer.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_rst_sync"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

cp "$BASE/tb/tb_rst_sync.sv" .
cp "$BASE/rtl/rst_sync.sv" .

verilator --binary --timing -j 4 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_rst_sync -o sim_rst \
  tb_rst_sync.sv rst_sync.sv > build.log 2>&1 \
  || { echo "BUILD FAILED"; grep -E "^%Error|^%Warning" build.log | head -10; exit 1; }

./obj_dir/sim_rst 2>&1 | grep -E "^\[TB\]|RST_SYNC_" | head -12
