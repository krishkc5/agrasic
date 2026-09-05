#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$BASE/rtl"
echo "=== full RV32I chip top ==="
verilator --lint-only --timing -Irv32i -Ictrl --top-module agriasic_digital_rv32i_top \
  agriasic_digital_rv32i_top.sv \
  agriasic_rv32i_control_shell.sv \
  agriasic_digital_top.sv \
  rst_sync.sv \
  ctrl/measurement_fsm.sv ctrl/excitation_ctrl.sv ctrl/sar_controller.sv \
  rv32i/agriasic_rv32i_core.sv rv32i/agriasic_imem.sv rv32i/agriasic_dmem.sv \
  rv32i/agriasic_rv32i_mmio.sv 2>&1 | head -50
echo "=== top lint done ==="
