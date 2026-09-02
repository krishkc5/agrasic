#!/bin/bash
BASE="/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agriasic_digital_v2"
W="$HOME/agriasic_spi_diag"
rm -rf "$W"; mkdir -p "$W"; cd "$W"
cp "$BASE/tb/tb_spi_diag.sv" .
cp "$BASE/rtl/agriasic_digital_spi_top.sv" "$BASE/rtl/agriasic_digital_top.sv" .
cp "$BASE/rtl/ctrl/measurement_fsm.sv" "$BASE/rtl/ctrl/excitation_ctrl.sv" .
cp "$BASE/rtl/ctrl/sar_controller.sv" "$BASE/rtl/ctrl/spi_slave.sv" "$BASE/rtl/ctrl/regfile.sv" .
verilator --binary --timing -j 4 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-UNOPTFLAT \
  --top-module tb_spi_diag -o sim_spi_diag \
  tb_spi_diag.sv agriasic_digital_spi_top.sv agriasic_digital_top.sv \
  measurement_fsm.sv excitation_ctrl.sv sar_controller.sv spi_slave.sv regfile.sv \
  > /tmp/spi_diag_build.log 2>&1 || { echo "BUILD FAILED"; grep -E "^%Error" /tmp/spi_diag_build.log | head -8; exit 1; }
./obj_dir/sim_spi_diag 2>&1 | head -20
