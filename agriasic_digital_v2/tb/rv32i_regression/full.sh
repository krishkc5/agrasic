#!/bin/bash
set -e
W="$HOME/agriasic_regression"; cd "$W"; source "$HOME/rv-venv/bin/activate"
# handleTrace() resolves this path unconditionally, even when tracingMode is
# None, so it must exist relative to sim_build (../../hw3-singlecycle/).
mkdir -p "$HOME/hw3-singlecycle"
cp "$W/cycle_status.sv" "$HOME/hw3-singlecycle/cycle_status.sv"

echo "riscv-tests visible as: $(ls ../riscv-tests/isa/rv32ui-p-simple 2>/dev/null || echo MISSING)"
# Run the full suite using the timing-adjusted testbench (identical checks,
# cycle counts corrected for the synchronous-SRAM latency).
python runner_timing.py > /tmp/full_run.log 2>&1 || true
grep -E "TESTS=" /tmp/full_run.log | tail -2
