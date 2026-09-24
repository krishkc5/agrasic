#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_e2e"
rm -rf "$W"; mkdir -p "$W"
cd "$W"
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/tb/tb_agriasic_rv32i_e2e.sv" .
cp "$BASE/fw/agriasic_fw.hex" .
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" .
stage_ibex
echo "=== firmware image: $(wc -l < agriasic_fw.hex) words ==="
echo "=== building simulation ==="
verilator --binary --timing --assert -j 4 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_agriasic_rv32i_e2e \
  -o sim_e2e \
  $IBEX_ARGS \
  tb_agriasic_rv32i_e2e.sv $AGRIASIC_RV32I_SOURCES \
  2>&1 | grep -E "^%(Error|Warning)" | grep -vE "UNUSED(PARAM|SIGNAL)|DECLFILENAME" | head -20 || true
echo "=== running ==="
./obj_dir/sim_e2e 2>&1 | tail -30
