#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Parent dir holding both agriasic_digital_v2 and the external cis5710 class repo.
# Override with AGRIASIC_SRC_ROOT if the class repo lives elsewhere.
SRC="${AGRIASIC_SRC_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
W="$HOME/agriasic_regression"
echo "staging into $W"
rm -rf "$W"
mkdir -p "$W/common/python"
RTL="$SRC/agriasic_digital_v2/rtl/rv32i"
HW5="$SRC/cis5710-tjammula/hw5-pipelined"
for f in agriasic_rv32i_core.sv agriasic_rv32i_cla.sv agriasic_rv32i_divider.sv cycle_status.sv RvDisassembler.sv; do
  cp "$RTL/$f" "$W/"
done
cp "$HW5/mem_initial_contents.hex" "$W/"
cp "$HW5/testbench.py" "$W/agriasic_tb.py"
cp "$SRC/cis5710-tjammula/common/python/"*.py "$W/common/python/"
echo "--- staged ---"
ls "$W"
