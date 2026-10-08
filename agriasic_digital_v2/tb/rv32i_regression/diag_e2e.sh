#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_e2e"; mkdir -p "$W"; cd "$W"
source "$SCRIPT_DIR/ibex_sources.sh"
# Re-copy ALL sources, not just the testbench, so RTL edits are picked up.
cp "$BASE/tb/tb_diag.sv" .
cp "$BASE/rtl/"*.sv . 2>/dev/null || true
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" "$BASE/rtl/rv32i/agriasic_spi_host.sv" .
cp "$BASE/fw/agriasic_fw.hex" .
stage_ibex
verilator --binary --timing -j 4 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_diag -o sim_diag \
  $IBEX_ARGS tb_diag.sv $AGRIASIC_RV32I_SOURCES \
  > /tmp/diag_build.log 2>&1 || { tail -20 /tmp/diag_build.log; exit 1; }
./obj_dir/sim_diag 2>&1 | head -60
