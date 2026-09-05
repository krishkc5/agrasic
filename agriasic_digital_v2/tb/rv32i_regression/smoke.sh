#!/bin/bash
# Measurement smoke test (tb_agriasic_digital_top).
#
# This used to build BOTH sar_controller.sv and its pre-fix sar_controller.sv.orig
# for comparison. That comparison stopped being meaningful after the Rev 4.3
# settle fix (see MAS section 5.3) and is now structurally impossible after the
# Rev 4.3 SAR bit-trial rewrite: .orig still expects the old adc_code_i port,
# which no longer exists anywhere in the digital_top hierarchy. sar_controller.sv
# is the only build target now.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_smoke"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
cp "$BASE/tb/smoke/tb_agriasic_digital_top.sv" .
cp "$BASE/rtl/agriasic_digital_top.sv" .
cp "$BASE/rtl/ctrl/measurement_fsm.sv" "$BASE/rtl/ctrl/excitation_ctrl.sv" "$BASE/rtl/ctrl/sar_controller.sv" .
verilator --binary --timing -j 4 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_agriasic_digital_top -o sim_smoke \
  tb_agriasic_digital_top.sv agriasic_digital_top.sv measurement_fsm.sv \
  excitation_ctrl.sv sar_controller.sv > build.log 2>&1 \
  || { echo "BUILD FAILED"; tail -15 build.log; exit 1; }
./obj_dir/sim_smoke 2>&1 | grep -E "SMOKE_|Error" | head -5
