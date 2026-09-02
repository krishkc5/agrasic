#!/bin/bash
BASE="/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agriasic_digital_v2"
W="$HOME/agriasic_smoke"
run_smoke () {
  rm -rf "$W"; mkdir -p "$W"; cd "$W"
  cp "$BASE/tb/smoke/tb_agriasic_digital_top.sv" .
  cp "$BASE/rtl/agriasic_digital_top.sv" .
  cp "$BASE/rtl/ctrl/measurement_fsm.sv" "$BASE/rtl/ctrl/excitation_ctrl.sv" .
  cp "$1" ./sar_controller.sv
  verilator --binary --timing -j 4 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
    --top-module tb_agriasic_digital_top -o sim_smoke \
    tb_agriasic_digital_top.sv agriasic_digital_top.sv measurement_fsm.sv \
    excitation_ctrl.sv sar_controller.sv > /tmp/smoke_build.log 2>&1 \
    || { echo "BUILD FAILED"; tail -15 /tmp/smoke_build.log; return 1; }
  ./obj_dir/sim_smoke 2>&1 | grep -E "SMOKE_|Error" | head -5
}
echo "########## WITH ORIGINAL sar_controller (before my fix) ##########"
run_smoke "$BASE/rtl/ctrl/sar_controller.sv.orig"
echo ""
echo "########## WITH FIXED sar_controller ##########"
run_smoke "$BASE/rtl/ctrl/sar_controller.sv"
