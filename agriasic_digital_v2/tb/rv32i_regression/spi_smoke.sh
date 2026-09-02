#!/bin/bash
BASE="/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agriasic_digital_v2"
W="$HOME/agriasic_spi"
run_spi () {
  rm -rf "$W"; mkdir -p "$W"; cd "$W"
  cp "$BASE/tb/smoke/tb_agriasic_digital_spi_top.sv" .
  cp "$BASE/rtl/agriasic_digital_spi_top.sv" "$BASE/rtl/agriasic_digital_top.sv" .
  cp "$BASE/rtl/ctrl/measurement_fsm.sv" "$BASE/rtl/ctrl/excitation_ctrl.sv" .
  cp "$BASE/rtl/ctrl/spi_slave.sv" "$BASE/rtl/ctrl/regfile.sv" .
  cp "$1" ./sar_controller.sv
  verilator --binary --timing -j 4 \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-UNOPTFLAT \
    --top-module tb_agriasic_digital_spi_top -o sim_spi \
    tb_agriasic_digital_spi_top.sv agriasic_digital_spi_top.sv agriasic_digital_top.sv \
    measurement_fsm.sv excitation_ctrl.sv sar_controller.sv spi_slave.sv regfile.sv \
    > /tmp/spi_build.log 2>&1 || { echo "BUILD FAILED"; grep -E "^%Error|^%Warning" /tmp/spi_build.log | head -8; return 1; }
  ./obj_dir/sim_spi 2>&1 | grep -E "SPI_TOP|ASSERT_FAIL|PASS|FAIL|Error" | head -8
}
echo "########## ORIGINAL sar_controller ##########"
run_spi "$BASE/rtl/ctrl/sar_controller.sv.orig"
echo ""
echo "########## FIXED sar_controller ##########"
run_spi "$BASE/rtl/ctrl/sar_controller.sv"
