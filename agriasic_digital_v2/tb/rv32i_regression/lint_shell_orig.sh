#!/bin/bash
# Lints the microsequencer descope-fallback shell (agriasic_rv32i_control_shell.sv.orig)
# against the CURRENT rv32i/ sibling files.
#
# Why this script exists (MAS GAP-8): section 4.2 documents a standing rule
# that agriasic_rv32i_control_shell.sv and its .orig alternative must stay
# port-identical, since either can be dropped into agriasic_digital_rv32i_top.sv
# unmodified as a schedule descope. Nothing enforced that automatically --
# .orig was never referenced by any script -- and Phase 5 found it had
# quietly drifted (cfg_exc_divider_o still 8 bits, three phases after the
# real shell went to 14). This script exists so that drift is caught by
# `verify_all.sh` going forward instead of found by hand again.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
W="$HOME/agriasic_lint_shell_orig"
rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
cp "$BASE/rtl/agriasic_rv32i_control_shell.sv.orig" control_shell_orig.sv
cp -r "$BASE/rtl/rv32i" .
echo "=== control shell .orig hierarchy (descope fallback) ==="
verilator --lint-only --timing -Irv32i --top-module agriasic_rv32i_control_shell \
  control_shell_orig.sv \
  rv32i/agriasic_rv32i_core.sv \
  rv32i/agriasic_imem.sv \
  rv32i/agriasic_dmem.sv \
  rv32i/agriasic_rv32i_mmio.sv 2>&1 | head -40
echo "=== shell .orig lint done ==="
