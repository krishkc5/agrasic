#!/bin/bash
# SPI-flash boot regression (Phase 3): program memory starts empty and the
# boot FSM loads it from a behavioural SPI NOR holding fw/agriasic_fw_flash.hex.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_flash_boot"
rm -rf "$W"; mkdir -p "$W"
cd "$W"
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/tb/tb_agriasic_flash_boot.sv" "$BASE/tb/tb_spi_flash_model.sv" .
cp "$BASE/fw/agriasic_fw.hex" "$BASE/fw/agriasic_fw_flash.hex" "$BASE/fw/golden/agriasic_fw_golden.hex" .
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" .
stage_ibex
echo "=== building SPI-flash boot simulation ==="
verilator --binary --timing --assert -j 4 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_agriasic_flash_boot -o sim_flash \
  $IBEX_ARGS tb_agriasic_flash_boot.sv tb_spi_flash_model.sv $AGRIASIC_RV32I_SOURCES \
  2>&1 | grep -E "^%(Error|Warning)" | grep -vE "UNUSED(PARAM|SIGNAL)|DECLFILENAME|UNOPTFLAT" | head -20 || true
echo "=== running ==="
./obj_dir/sim_flash 2>&1 | tail -45
