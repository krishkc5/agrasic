#!/bin/bash
# Shared helper: stage the vendored Ibex core and RISC-V debug module into the
# current work directory and expose the Verilator arguments to compile them.
#
# Usage (from a script that has already set BASE and cd'ed into its workdir):
#   source "$SCRIPT_DIR/ibex_sources.sh"
#   stage_ibex            # copies $BASE/rtl/ibex and $BASE/rtl/riscv-dbg here
#   verilator ... $IBEX_ARGS <agriasic sources>
#
# The repo path contains spaces, which Verilator's generated Makefile cannot
# handle, so every script builds in a space-free $HOME workdir; the vendored
# trees are copied there with their subdirectory layout intact so the .f
# lists stay valid.

stage_ibex() {
  rm -rf ibex riscv-dbg
  cp -r "$BASE/rtl/ibex" ibex
  cp -r "$BASE/rtl/riscv-dbg" riscv-dbg
  # Compile lists in the order proven by each VENDOR.md's lint harness.
  IBEX_FILES="$(sed 's#^#ibex/#' ibex/ibex.f | tr '\n' ' ')"
  DBG_FILES="$(sed 's#^#riscv-dbg/#' riscv-dbg/riscv_dbg.f | tr '\n' ' ')"
  IBEX_ARGS="+incdir+ibex/prim +incdir+ibex/dv_utils +incdir+riscv-dbg/common_cells/include ibex/lint/verilator_waiver.vlt riscv-dbg/lint/agriasic_waiver.vlt $DBG_FILES $IBEX_FILES"
  export IBEX_ARGS
}

# Sources for the RV32I chip build that are NOT vendored IP. Kept here so
# every script agrees on the list (the Penn core files under rtl/rv32i are no
# longer part of the chip build).
AGRIASIC_RV32I_SOURCES="agriasic_digital_rv32i_top.sv agriasic_rv32i_control_shell.sv agriasic_digital_top.sv rst_sync.sv measurement_fsm.sv excitation_ctrl.sv sar_controller.sv agriasic_imem.sv agriasic_dmem.sv agriasic_rv32i_mmio.sv agriasic_rv32i_bus.sv agriasic_spi_boot.sv"
export AGRIASIC_RV32I_SOURCES
