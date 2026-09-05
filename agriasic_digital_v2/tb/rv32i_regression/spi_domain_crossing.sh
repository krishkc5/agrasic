#!/bin/bash
# Unit regression for the Rev 4.3 Phase 3 SPI clk-domain rework.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_spi_xcross"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

cp "$BASE/tb/tb_spi_domain_crossing.sv" .
cp "$BASE/rtl/ctrl/spi_slave.sv" .

verilator --binary --timing -j 4 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-INITIALDLY \
  --top-module tb_spi_domain_crossing -o sim_xcross \
  tb_spi_domain_crossing.sv spi_slave.sv > build.log 2>&1 \
  || { echo "BUILD FAILED"; grep -E "^%Error|^%Warning" build.log | head -10; exit 1; }

./obj_dir/sim_xcross 2>&1 | grep -E "^\[TB\]|SPI_XCROSS|SPI_DOMAIN_CROSSING_" | head -20
