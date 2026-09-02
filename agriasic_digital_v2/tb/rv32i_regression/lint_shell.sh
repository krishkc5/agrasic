#!/bin/bash
cd "/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agriasic_digital_v2/rtl"
echo "=== control shell hierarchy ==="
verilator --lint-only --timing -Irv32i --top-module agriasic_rv32i_control_shell \
  agriasic_rv32i_control_shell.sv \
  rv32i/agriasic_rv32i_core.sv \
  rv32i/agriasic_imem.sv \
  rv32i/agriasic_dmem.sv \
  rv32i/agriasic_rv32i_mmio.sv 2>&1 | head -40
echo "=== shell lint done ==="
