#!/bin/bash
# Power-up end to end, SPI flash boot: one reset release, the boot FSM reads
# fw/agriasic_fw_flash.hex out of a behavioural SPI NOR into an empty IMEM and
# checks its CRC, then the firmware sweep runs to FW_DONE and parks. Same bench
# as boot_rom_e2e.sh.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/waves.sh"
W="$HOME/agriasic_boot_flash_e2e"
rm -rf "$W"; mkdir -p "$W"
cd "$W"
wave_setup tb_agriasic_boot_e2e boot_flash_e2e
source "$SCRIPT_DIR/ibex_sources.sh"
cp "$BASE/tb/tb_agriasic_boot_e2e.sv" "$BASE/tb/tb_spi_flash_model.sv" .
cp "$BASE/fw/agriasic_fw_flash.hex" .
cp "$BASE/rtl/"*.sv .
cp "$BASE/rtl/ctrl/"*.sv .
cp "$BASE/rtl/rv32i/agriasic_imem.sv" "$BASE/rtl/rv32i/agriasic_dmem.sv" "$BASE/rtl/rv32i/agriasic_rv32i_mmio.sv" "$BASE/rtl/rv32i/agriasic_rv32i_bus.sv" "$BASE/rtl/rv32i/agriasic_spi_boot.sv" "$BASE/rtl/rv32i/agriasic_boot_rom.sv" "$BASE/rtl/rv32i/agriasic_spi_host.sv" .
stage_ibex
echo "=== building power-up end-to-end simulation (SPI flash boot) ==="
verilator $WAVE_ARGS --binary --timing --assert -j 4 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
  --top-module tb_agriasic_boot_e2e -GBOOT_FROM_FLASH=1 -o sim_boot_flash \
  $IBEX_ARGS tb_agriasic_boot_e2e.sv tb_spi_flash_model.sv $AGRIASIC_RV32I_SOURCES \
  2>&1 | grep -E "^%(Error|Warning)" | grep -vE "UNUSED(PARAM|SIGNAL)|DECLFILENAME|UNOPTFLAT" | head -20 || true
echo "=== running ==="
./obj_dir/sim_boot_flash 2>&1 | tail -80   # boot ~15 lines, sweep ~45
wave_report
