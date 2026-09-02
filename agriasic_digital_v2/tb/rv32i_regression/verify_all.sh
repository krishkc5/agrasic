#!/bin/bash
# Final verification sweep across every level of the design.
R="/mnt/c/Users/taara/UPENN SR FALL/SR DESIGN/agriasic_digital_v2/tb/rv32i_regression"

echo "=================================================="
echo "1. FULL CHIP LINT (RV32I top)"
echo "=================================================="
bash "$R/lint_top.sh" 2>&1 | grep -E "^%Error|^%Warning-" | head -6
echo "(only pre-existing measurement_fsm width warnings expected)"

echo ""
echo "=================================================="
echo "2. MEASUREMENT SMOKE TEST (tb_agriasic_digital_top)"
echo "=================================================="
bash "$R/smoke.sh" 2>&1 | grep -E "SMOKE_PASS|SMOKE_FAIL|##" | tail -4

echo ""
echo "=================================================="
echo "3. SPI SMOKE TEST (tb_agriasic_digital_spi_top)"
echo "=================================================="
bash "$R/spi_smoke.sh" 2>&1 | grep -E "SPI_TOP_SMOKE_PASS|SPI_TOP_.*FAIL|##" | tail -4

echo ""
echo "=================================================="
echo "4. END-TO-END FIRMWARE + MEASUREMENT"
echo "=================================================="
bash "$R/e2e.sh" 2>&1 | grep -E "^\[TB\]" | tail -12
