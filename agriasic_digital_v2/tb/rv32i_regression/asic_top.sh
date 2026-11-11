#!/bin/bash
# Chip-top simulation: firmware + digital + the analog front-end macro.
#
# Behavioural AFE build. AGRIASIC_AFE_BEHAVIORAL selects the real-valued
# model in rtl/analog/ and the real-valued analog ports on agriasic_asic_top;
# the synthesis build defines nothing and uses lib/agriasic_afe_top.lib.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_asic_top"
rm -rf "$W"; mkdir -p "$W"
cd "$W"
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/tb/tb_agriasic_asic_top.sv" .
cp "$BASE/fw/agriasic_fw.hex" .
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/analog/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" "$BASE/rtl/rv32i/agriasic_spi_host.sv" .
stage_ibex
echo "=== building chip-top simulation ==="
verilator --binary --timing --assert -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  -DAGRIASIC_AFE_BEHAVIORAL \
  --top-module tb_agriasic_asic_top \
  -o sim_asic_top \
  $IBEX_ARGS \
  agriasic_afe_pkg.sv agriasic_afe_top.sv agriasic_asic_top.sv \
  tb_agriasic_asic_top.sv $AGRIASIC_RV32I_SOURCES \
  2>&1 | grep -E "^%(Error|Warning)|error:" | grep -vE "UNUSED(PARAM|SIGNAL)|DECLFILENAME|UNOPTFLAT" | head -20 || true
echo "=== running ==="
./obj_dir/sim_asic_top 2>&1 | tail -60
