#!/bin/bash
# JTAG / RISC-V debug module regression (Phase 2): tb_agriasic_jtag drives the
# chip's JTAG pins through the DTM/DM protocol against the live firmware.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_jtag"
rm -rf "$W"; mkdir -p "$W"
cd "$W"
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/tb/tb_agriasic_jtag.sv" .
cp "$BASE/fw/agriasic_fw.hex" .
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" .
stage_ibex
echo "=== building JTAG debug simulation ==="
verilator --binary --timing --assert -j 4 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_agriasic_jtag -o sim_jtag \
  $IBEX_ARGS tb_agriasic_jtag.sv $AGRIASIC_RV32I_SOURCES \
  2>&1 | grep -E "^%(Error|Warning)" | grep -vE "UNUSED(PARAM|SIGNAL)|DECLFILENAME|UNOPTFLAT" | head -20 || true
echo "=== running ==="
./obj_dir/sim_jtag 2>&1 | tail -45
