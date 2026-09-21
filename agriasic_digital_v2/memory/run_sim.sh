#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d /tmp/agriasic-memory.XXXXXX)"
mkdir -p "$BASE/memory/results" "$BASE/memory/build"
python3 "$BASE/memory/prepare_sim.py"
cp "$BASE/memory/build/tb_memory_generated.sv" "$BUILD/"
cp "$BASE/fw/agriasic_fw.hex" "$BUILD/"
cp "$BASE"/rtl/*.sv "$BASE"/rtl/ctrl/*.sv "$BUILD/"
cp "$BASE"/rtl/rv32i/agriasic_imem.sv "$BASE"/rtl/rv32i/agriasic_dmem.sv "$BASE"/rtl/rv32i/agriasic_rv32i_mmio.sv "$BASE"/rtl/rv32i/agriasic_rv32i_bus.sv "$BUILD/"
cp -r "$BASE/rtl/ibex" "$BUILD/ibex"
cp -r "$BASE/rtl/riscv-dbg" "$BUILD/riscv-dbg"
cd "$BUILD"
verilator --version > "$BASE/memory/results/tool_versions.txt"
IBEX_FILES="$(sed 's#^#ibex/#' ibex/ibex.f | tr '\n' ' ')"
DBG_FILES="$(sed 's#^#riscv-dbg/#' riscv-dbg/riscv_dbg.f | tr '\n' ' ')"
verilator --binary --timing --assert -j 4 -Wno-fatal \
 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
 --top-module tb_agriasic_rv32i_e2e -o sim_memory \
 +incdir+ibex/prim +incdir+ibex/dv_utils +incdir+riscv-dbg/common_cells/include ibex/lint/verilator_waiver.vlt riscv-dbg/lint/agriasic_waiver.vlt $DBG_FILES $IBEX_FILES \
 tb_memory_generated.sv agriasic_digital_rv32i_top.sv \
 agriasic_rv32i_control_shell.sv agriasic_digital_top.sv rst_sync.sv \
 measurement_fsm.sv excitation_ctrl.sv sar_controller.sv \
 agriasic_imem.sv agriasic_dmem.sv agriasic_rv32i_mmio.sv agriasic_rv32i_bus.sv \
 > "$BASE/memory/build/build.log" 2>&1
./obj_dir/sim_memory > "$BASE/memory/results/simulation.log" 2>&1
cp accesses.csv "$BASE/memory/results/"
printf '%s\n' "$BUILD" > "$BASE/memory/build/linux_build_path.txt"
cat "$BASE/memory/results/simulation.log"
