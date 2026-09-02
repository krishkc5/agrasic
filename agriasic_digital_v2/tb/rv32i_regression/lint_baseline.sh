#!/bin/bash
cd "/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agriasic_digital_v2/rtl"
echo "=== PRE-EXISTING measurement hierarchy (untouched by this work) ==="
verilator --lint-only --timing -Ictrl --top-module agriasic_digital_top \
  agriasic_digital_top.sv ctrl/measurement_fsm.sv ctrl/excitation_ctrl.sv ctrl/sar_controller.sv 2>&1 \
  | grep -E "^%Warning|^%Error" | head -10
echo "=== baseline done ==="
