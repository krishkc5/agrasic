#!/bin/bash
# SPI-wrapped smoke test (tb_agriasic_digital_spi_top).
#
# Retired the .orig sar_controller comparison leg -- see smoke.sh for why:
# it is structurally incompatible with the Rev 4.3 SAR bit-trial interface.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_spi"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
cp "$BASE/tb/smoke/tb_agriasic_digital_spi_top.sv" .
cp "$BASE/rtl/agriasic_digital_spi_top.sv" "$BASE/rtl/agriasic_digital_top.sv" "$BASE/rtl/rst_sync.sv" .
cp "$BASE/rtl/ctrl/measurement_fsm.sv" "$BASE/rtl/ctrl/excitation_ctrl.sv" .
cp "$BASE/rtl/ctrl/sar_controller.sv" "$BASE/rtl/ctrl/spi_slave.sv" "$BASE/rtl/ctrl/regfile.sv" .
verilator --binary --timing -j 4 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-UNOPTFLAT \
  --top-module tb_agriasic_digital_spi_top -o sim_spi \
  tb_agriasic_digital_spi_top.sv agriasic_digital_spi_top.sv agriasic_digital_top.sv rst_sync.sv \
  measurement_fsm.sv excitation_ctrl.sv sar_controller.sv spi_slave.sv regfile.sv \
  > build.log 2>&1 || { echo "BUILD FAILED"; grep -E "^%Error|^%Warning" build.log | head -8; exit 1; }
./obj_dir/sim_spi 2>&1 | grep -E "SPI_TOP|ASSERT_FAIL|PASS|FAIL|Error" | head -8
