#!/bin/bash
grep -E "AssertionError|SimTimeoutError|Could not find|failed test|Traceback" /tmp/full_run.log | sort | uniq -c | sort -rn | head -15
echo "=== first riscvTest failure context ==="
grep -A12 "riscvTest_001" /tmp/full_run.log | head -25
