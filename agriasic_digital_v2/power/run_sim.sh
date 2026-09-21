#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d /tmp/agriasic-power.XXXXXX)"
mkdir -p "$BASE/power/results" "$BASE/power/build" "$BUILD/results" "$BUILD/work"
python3 "$BASE/power/prepare_sim.py"
cp "$BASE/power/build/tb_power_generated.sv" "$BUILD/work/"
cp "$BASE/fw/agriasic_fw.hex" "$BUILD/work/"
cp "$BASE"/rtl/*.sv "$BASE"/rtl/ctrl/*.sv "$BUILD/work/"
cp "$BASE"/rtl/rv32i/agriasic_imem.sv "$BASE"/rtl/rv32i/agriasic_dmem.sv "$BASE"/rtl/rv32i/agriasic_rv32i_mmio.sv "$BASE"/rtl/rv32i/agriasic_rv32i_bus.sv "$BUILD/work/"
cp -r "$BASE/rtl/ibex" "$BUILD/work/ibex"
cp -r "$BASE/rtl/riscv-dbg" "$BUILD/work/riscv-dbg"
cd "$BUILD/work"
SOURCES=(
 agriasic_digital_rv32i_top.sv agriasic_rv32i_control_shell.sv
 agriasic_digital_top.sv rst_sync.sv measurement_fsm.sv excitation_ctrl.sv
 sar_controller.sv agriasic_imem.sv agriasic_dmem.sv
 agriasic_rv32i_mmio.sv agriasic_rv32i_bus.sv
)
IBEX_FILES="$(sed 's#^#ibex/#' ibex/ibex.f | tr '\n' ' ')"
DBG_FILES="$(sed 's#^#riscv-dbg/#' riscv-dbg/riscv_dbg.f | tr '\n' ' ')"
IBEX_ARGS="+incdir+ibex/prim +incdir+ibex/dv_utils +incdir+riscv-dbg/common_cells/include ibex/lint/verilator_waiver.vlt riscv-dbg/lint/agriasic_waiver.vlt $DBG_FILES $IBEX_FILES"
verilator --version > "$BASE/power/results/tool_versions.txt"
# -DSYNTHESIS so the simulated hierarchy matches the synthesized one exactly
# (Ibex latch register file, prim_assert off); analyze_activity.py cross-checks
# every netlist register bit against a VCD signal.
verilator --binary --timing --assert --trace -j 4 -Wno-fatal -DSYNTHESIS \
 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
 --top-module tb_agriasic_rv32i_e2e -o sim_power \
 $IBEX_ARGS tb_power_generated.sv "${SOURCES[@]}" > "$BASE/power/build/build.log" 2>&1
./obj_dir/sim_power > "$BASE/power/results/simulation.log" 2>&1
cp "$BUILD/results/"*.csv "$BASE/power/results/"
cp activity.vcd "$BASE/power/build/"
printf '%s\n' "$BUILD" > "$BASE/power/build/linux_build_path.txt"
cat "$BASE/power/results/simulation.log"
