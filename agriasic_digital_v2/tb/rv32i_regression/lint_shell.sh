#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_lint"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/rtl/agriasic_rv32i_control_shell.sv" "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" .
stage_ibex
echo "=== control shell hierarchy (Ibex) ==="
verilator --lint-only --timing -Wall -Wno-fatal -Wno-TIMESCALEMOD --top-module agriasic_rv32i_control_shell \
  $IBEX_ARGS agriasic_rv32i_control_shell.sv agriasic_imem.sv agriasic_dmem.sv agriasic_rv32i_mmio.sv agriasic_rv32i_bus.sv \
  2>&1 | grep -vE "^%Warning-(UNUSEDPARAM|UNUSEDSIGNAL|DECLFILENAME)" | grep -E "^%" | head -40
echo "=== shell lint done ==="
