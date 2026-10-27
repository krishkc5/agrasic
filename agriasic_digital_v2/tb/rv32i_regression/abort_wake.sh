#!/bin/bash
# Abort-wake regression: a host abort must wake the core out of wfi rather than
# strand it there, and firmware must then finish its loop cleanly and report how
# many sweep points it actually completed. The abort is driven over the host SPI
# port (master M4), which is how a deployed host would issue it.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/waves.sh"
W="$HOME/agriasic_abort_wake"
rm -rf "$W"; mkdir -p "$W"
cd "$W"
wave_setup tb_abort_wake abort_wake
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/tb/tb_abort_wake.sv" .
cp "$BASE/fw/agriasic_fw.hex" .
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" "$BASE/rtl/rv32i/agriasic_spi_host.sv" .
stage_ibex
echo "=== building abort-wake simulation ==="
verilator $WAVE_ARGS --binary --timing --assert -j 4 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_abort_wake -o sim_abort_wake \
  $IBEX_ARGS tb_abort_wake.sv $AGRIASIC_RV32I_SOURCES \
  2>&1 | grep -E "^%(Error|Warning)" | grep -vE "UNUSED(PARAM|SIGNAL)|DECLFILENAME|UNOPTFLAT" | head -20 || true
echo "=== running ==="
./obj_dir/sim_abort_wake 2>&1 | tail -45
wave_report
