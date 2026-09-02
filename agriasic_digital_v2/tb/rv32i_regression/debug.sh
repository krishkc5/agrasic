#!/bin/bash
W="$HOME/agriasic_regression"
cd "$W"
source "$HOME/rv-venv/bin/activate"
export TESTS="$1"
python runner.py 2>&1 | grep -E "FAIL|PASS|assert|Error|expected|got|cycle|Traceback|File \"|Equals" | head -40
