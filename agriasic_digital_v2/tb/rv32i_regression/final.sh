#!/bin/bash
set -e
W="$HOME/agriasic_regression"; cd "$W"; source "$HOME/rv-venv/bin/activate"
python runner_notrace.py > /tmp/final_run.log 2>&1 || true
grep -E "TESTS=" /tmp/final_run.log | tail -1
echo "--- any failures? ---"
grep -E "FAIL " /tmp/final_run.log | head -10 || echo "none"
