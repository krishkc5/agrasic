#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_lint"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" .
stage_ibex
echo "=== full RV32I chip top (Ibex) ==="
verilator --lint-only --timing -Wno-fatal -Wno-TIMESCALEMOD --top-module agriasic_digital_rv32i_top \
  $IBEX_ARGS $AGRIASIC_RV32I_SOURCES \
  2>&1 | grep -vE "^%Warning-(UNUSEDPARAM|UNUSEDSIGNAL|DECLFILENAME)" | grep -E "^%" | head -50
echo "=== top lint done ==="
