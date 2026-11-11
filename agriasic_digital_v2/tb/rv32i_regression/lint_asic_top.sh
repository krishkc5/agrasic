#!/bin/bash
# Lint the CHIP top: digital top + the analog front-end macro.
#
# This is the behavioural build -- AGRIASIC_AFE_BEHAVIORAL selects the
# real-valued model in rtl/analog/ and the real-valued analog ports on
# agriasic_asic_top. The synthesis build defines nothing, omits rtl/analog/
# entirely, and resolves agriasic_afe_top from lib/agriasic_afe_top.lib.
#
# Kept separate from lint_top.sh on purpose: that script lints the SYNTHESIS
# target (agriasic_digital_rv32i_top) and must stay free of analog sources.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_lint_asic"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/analog/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" "$BASE/rtl/rv32i/agriasic_spi_host.sv" .
stage_ibex
echo "=== ASIC chip top (digital + AFE behavioural macro) ==="
verilator --lint-only --timing -Wno-fatal -Wno-TIMESCALEMOD \
  -DAGRIASIC_AFE_BEHAVIORAL \
  --top-module agriasic_asic_top \
  $IBEX_ARGS agriasic_afe_pkg.sv agriasic_afe_top.sv agriasic_asic_top.sv $AGRIASIC_RV32I_SOURCES \
  2>&1 | grep -vE "^%Warning-(UNUSEDPARAM|UNUSEDSIGNAL|DECLFILENAME)" | grep -E "^%" | head -50
echo "=== asic top lint done ==="
