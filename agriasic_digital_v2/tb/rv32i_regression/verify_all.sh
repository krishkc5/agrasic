#!/bin/bash
# Final verification sweep across every level of the design.
#
# ---------------------------------------------------------------------------
# Every stage is gated THREE ways, because no one of them is sufficient:
#
#   1. the stage must produce output at all.  A zero-byte log is the signature
#      of a build killed outright rather than failing -- WSL does this with
#      Wsl/Service/0x80072746, and the process dies before even the first echo
#      flushes.  No PASS, no FAIL, nothing.
#   2. the stage script must exit 0.
#   3. the stage's expected PASS token must appear in its output.
#
# (3) is the load-bearing gate.  Every stage script ends in a pipeline
# (`<sim> 2>&1 | tail -30`), so the script's exit status is the status of the
# LAST pipeline element -- almost always 0, even when the simulation never
# built.  This sweep used to pipe each stage straight into `grep | tail` with
# no check at all, which meant a stage that died contributed no output, no
# FAIL token, and an exit status of grep's.  A reader scanning the log for
# "FAIL" found none and concluded the run was green.
#
# That is not hypothetical.  On 2026-10-24 this sweep reported exit 0 on a run
# that died at stage 13 and never executed stages 13-16, and a blank stage 5
# in an earlier run was misread as "lint-style stage, no output expected" when
# in fact the stage had not run.  Before a tapeout freeze that failure mode is
# considerably worse than a red run.
#
# So do NOT "simplify" a stage back to a bare `bash "$R/x.sh" | grep ...`.
# Exit status is non-zero if any stage fails any gate.
# ---------------------------------------------------------------------------

R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/verify_all.XXXXXX")"
trap 'rm -rf "$LOGDIR"' EXIT

FAILED=()
PASSED=0

_hdr() {
  echo ""
  echo "=================================================="
  echo "$1"
  echo "=================================================="
}

# _gate <title> <log> <rc> <require_token> [forbid_pat]
# Applies the three gates plus an optional "this pattern must NOT appear"
# check (used by the lint stages, which have no PASS token of their own).
_gate() {
  local title="$1" log="$2" rc="$3" token="$4" forbid="$5"
  local why=""

  if [ ! -s "$log" ]; then
    why="produced NO OUTPUT AT ALL -- the stage did not run (killed, not failed)"
  else
    [ "$rc" -ne 0 ] && why="script exited $rc"
    if ! grep -qE -- "$token" "$log"; then
      why="${why:+$why; }required token /$token/ missing"
    fi
    if [ -n "$forbid" ] && grep -qE -- "$forbid" "$log"; then
      why="${why:+$why; }forbidden pattern /$forbid/ present"
    fi
  fi

  if [ -n "$why" ]; then
    echo "###"
    echo "### STAGE FAILED: $title"
    echo "###   $why"
    echo "###   last lines of its output:"
    if [ -s "$log" ]; then tail -8 "$log" | sed 's/^/###   | /'; else echo "###   | (empty)"; fi
    echo "###"
    FAILED+=("$title")
  else
    PASSED=$((PASSED + 1))
  fi
}

# stage <title> <script> <display_pat> <tail_n> <require_token>
stage() {
  local title="$1" script="$2" pat="$3" n="$4" token="$5"
  local log="$LOGDIR/${script%.sh}.log"
  _hdr "$title"
  bash "$R/$script" > "$log" 2>&1
  local rc=$?
  grep -E -- "$pat" "$log" | tail -"$n"
  _gate "$title" "$log" "$rc" "$token"
}

# stage_lint <title> <script> <end_marker>
# A lint stage passes on silence, so "no output" cannot be its pass criterion
# -- hence the end marker each lint script prints as its last line, which only
# appears if the script actually reached the end.
stage_lint() {
  local title="$1" script="$2" marker="$3"
  local log="$LOGDIR/${script%.sh}.log"
  _hdr "$title"
  bash "$R/$script" > "$log" 2>&1
  local rc=$?
  grep -E -- "^%Error|^%Warning-" "$log" | head -6
  echo "(lint is expected to be clean -- no output above this line)"
  _gate "$title" "$log" "$rc" "$marker" "^%Error"
}

stage_lint "1. FULL CHIP LINT (RV32I top)" \
  lint_top.sh "=== top lint done ==="

stage "2. MEASUREMENT SMOKE TEST (tb_agriasic_digital_top)" \
  smoke.sh "SMOKE_PASS|SMOKE_FAIL|##" 4 "SMOKE_PASS"

stage "3. SPI SMOKE TEST (tb_agriasic_digital_spi_top)" \
  spi_smoke.sh "SPI_TOP_SMOKE_PASS|SPI_TOP_.*FAIL|##" 4 "SPI_TOP_SMOKE_PASS"

stage "4. SAR BIT-TRIAL UNIT TEST (Rev 4.3 Phase 1)" \
  sar_bit_trial.sh "^\[TB\]|SAR_|ASSERT_FAIL" 14 "SAR_BIT_TRIAL_PASS"

stage "5. EXCITATION FREE-RUNNING PHASE GENERATOR (Rev 4.3 Phase 4)" \
  excitation_drive.sh "^\[TB\]|EXCITATION_|ASSERT_FAIL|BREAK_|WRONG_" 8 "EXCITATION_DRIVE_PASS"

stage "6. RESET SYNCHRONIZER (Rev 4.3 Phase 2.1)" \
  rst_sync_check.sh "^\[TB\]|RST_SYNC_" 10 "RST_SYNC_PASS"

stage "7. SPI CLK-DOMAIN REWORK (Rev 4.3 Phase 3)" \
  spi_domain_crossing.sh "^\[TB\]|SPI_XCROSS|SPI_DOMAIN_CROSSING_" 10 "SPI_DOMAIN_CROSSING_PASS"

stage "8. SETTLE TIMING REGRESSION (Rev 4.3 defects 1 and 2)" \
  settle_check.sh "^\[TB\]|SETTLE_" 8 "SETTLE_TIMING_PASS"

stage "9. END-TO-END FIRMWARE + MEASUREMENT (Ibex core, wfi sleep)" \
  e2e.sh "^\[TB\]" 13 "PASS -- all checks passed"

stage_lint "10. CONTROL SHELL DESCOPE FALLBACK LINT (.orig, closes GAP-8)" \
  lint_shell_orig.sh "=== shell .orig lint done ==="

stage "11. ACCUMULATOR EDGE CASES (Rev 4.3 Phase 8, closes V-2)" \
  accum_edge_cases.sh "^\[TB\]|ACCUM_EDGE_" 8 "ACCUM_EDGE_PASS"

stage "12. SETTLE x CONV GRID SWEEP (Rev 4.3 Phase 8, closes V-1)" \
  settle_conv_sweep.sh "^\[TB\]|SETTLE_CONV_" 12 "SETTLE_CONV_SWEEP_PASS"

stage "13. JTAG / RISC-V DEBUG MODULE (halt, abstract regs, SBA, resume, ndmreset with a measurement in flight)" \
  jtag.sh "^\[TB\]|JTAG_DEBUG_" 8 "JTAG_DEBUG_PASS"

stage "14. BOOT: GOLDEN ROM + SPI FLASH (header/CRC into IMEM, fail-hold, retry, strap override)" \
  flash_boot.sh "^\[TB\] [A-G]:|FLASH_BOOT_" 12 "FLASH_BOOT_PASS"

stage "15. HOST SPI PORT (M4: read/write while the core runs, permissions, gain decode, abort/restart)" \
  spi_host.sh "^\[TB\]   [A-H]:|SPI_HOST_" 50 "SPI_HOST_PASS"

stage "16. ABORT WAKES THE CORE (a host abort must not strand firmware in wfi)" \
  abort_wake.sh "^\[TB\]|ABORT_WAKE_" 16 "ABORT_WAKE_PASS"

_hdr "SUMMARY"
TOTAL=$((PASSED + ${#FAILED[@]}))
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "VERIFY_ALL_PASS -- $PASSED/$TOTAL stages passed all gates"
  exit 0
fi
echo "VERIFY_ALL_FAIL -- $PASSED/$TOTAL stages passed; ${#FAILED[@]} failed:"
for f in "${FAILED[@]}"; do echo "  - $f"; done
exit 1
