#!/bin/bash
# Final verification sweep across every level of the design.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=================================================="
echo "1. FULL CHIP LINT (RV32I top)"
echo "=================================================="
bash "$R/lint_top.sh" 2>&1 | grep -E "^%Error|^%Warning-" | head -6
echo "(lint is expected to be clean -- no output above this line)"

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
echo "4. SAR BIT-TRIAL UNIT TEST (Rev 4.3 Phase 1)"
echo "=================================================="
bash "$R/sar_bit_trial.sh" 2>&1 | grep -E "^\[TB\]|SAR_|ASSERT_FAIL" | tail -14

echo ""
echo "=================================================="
echo "5. EXCITATION FREE-RUNNING PHASE GENERATOR (Rev 4.3 Phase 4)"
echo "=================================================="
bash "$R/excitation_drive.sh" 2>&1 | grep -E "^\[TB\]|EXCITATION_|ASSERT_FAIL|BREAK_|WRONG_" | tail -8

echo ""
echo "=================================================="
echo "6. RESET SYNCHRONIZER (Rev 4.3 Phase 2.1)"
echo "=================================================="
bash "$R/rst_sync_check.sh" 2>&1 | grep -E "^\[TB\]|RST_SYNC_" | tail -10

echo ""
echo "=================================================="
echo "7. SPI CLK-DOMAIN REWORK (Rev 4.3 Phase 3)"
echo "=================================================="
bash "$R/spi_domain_crossing.sh" 2>&1 | grep -E "^\[TB\]|SPI_XCROSS|SPI_DOMAIN_CROSSING_" | tail -10

echo ""
echo "=================================================="
echo "8. SETTLE TIMING REGRESSION (Rev 4.3 defects 1 and 2)"
echo "=================================================="
bash "$R/settle_check.sh" 2>&1 | grep -E "^\[TB\]|SETTLE_" | tail -8

echo ""
echo "=================================================="
echo "9. END-TO-END FIRMWARE + MEASUREMENT (incl. core clock enable, Phase 2.2)"
echo "=================================================="
bash "$R/e2e.sh" 2>&1 | grep -E "^\[TB\]" | tail -13

echo ""
echo "=================================================="
echo "10. CONTROL SHELL DESCOPE FALLBACK LINT (.orig, closes GAP-8)"
echo "=================================================="
bash "$R/lint_shell_orig.sh" 2>&1 | grep -E "^%Error|^%Warning-" | head -6
echo "(lint is expected to be clean -- no output above this line)"

echo ""
echo "=================================================="
echo "11. ACCUMULATOR EDGE CASES (Rev 4.3 Phase 8, closes V-2)"
echo "=================================================="
bash "$R/accum_edge_cases.sh" 2>&1 | grep -E "^\[TB\]|ACCUM_EDGE_" | tail -8

echo ""
echo "=================================================="
echo "12. SETTLE x CONV GRID SWEEP (Rev 4.3 Phase 8, closes V-1)"
echo "=================================================="
bash "$R/settle_conv_sweep.sh" 2>&1 | grep -E "^\[TB\]|SETTLE_CONV_" | tail -6
